# frozen_string_literal: true

require "json"

module Nostr
  # Long-lived NIP-46 relay listener for the login/pairing background job.
  # Runs one thread per auth relay, each keeping a persistent WebSocket
  # subscription alive until the full handshake completes or the session expires.
  #
  # Handshake is two phases:
  #   1. Read kind-24133 events p-tagged to our client pubkey, decrypt,
  #      validate the connect secret, record the signer pubkey.
  #   2. Send a get_public_key NIP-46 request to that signer, await the
  #      response, extract the user pubkey, and persist both atomically.
  #
  # Both phases are coordinated across all relay threads via a shared
  # Handshake state object: as soon as ANY relay sees the connect response,
  # EVERY relay sends get_public_key and watches for the reply, and a reply
  # arriving on ANY relay completes the handshake. This makes phase 2 robust
  # to relay flakiness — Amber's reply is caught on whichever relay is alive,
  # instead of betting on the single socket that happened to see the connect ack.
  #
  # The user pubkey from get_public_key is the real Nostr identity; the
  # signer pubkey is only for NIP-46 routing/encryption and may be a
  # per-connection identity in newer Amber versions.
  class Nip46Listener
    POLL_INTERVAL = 1 # seconds between IO.select checks

    # Thread-safe coordination shared by every relay thread for one session.
    # Pins one signer and one logical get_public_key request shared by all relays.
    class Handshake
      def initialize
        @mutex = Mutex.new
        @signer_pubkey = nil
        @request = nil
      end

      def signer_pubkey
        @mutex.synchronize { @signer_pubkey }
      end

      # Record the signer pubkey if not already set; returns the effective one.
      def set_signer(pubkey)
        @mutex.synchronize { @signer_pubkey ||= pubkey }
      end

      def request(client)
        @mutex.synchronize do
          @request ||= client.build_request_event(@signer_pubkey, "get_public_key", [])
        end
      end

      def known_request?(id)
        return false unless id
        @mutex.synchronize { @request && @request[:request_id] == id }
      end
    end

    def initialize(auth_session, lease_token: nil)
      @auth_session = auth_session
      @lease_token = lease_token
      @relay_urls = auth_session.relay_urls
      @temp_pubkey = auth_session.temp_pubkey
      @client = Nip46Client.new(auth_session)
    end

    # Listen on all relays simultaneously. Returns user pubkey or nil.
    def listen_for_connect
      deadline = @auth_session.expires_at
      Rails.logger.info("NIP-46 listener starting for #{@temp_pubkey[0..7]}... on #{@relay_urls.join(', ')} until #{deadline}")

      state = Handshake.new
      result = nil
      threads = @relay_urls.map do |relay_url|
        Thread.new do
          # Check a DB connection out only for this thread's lifetime and return
          # it to the pool when the thread ends, instead of leaking one per relay.
          ActiveRecord::Base.connection_pool.with_connection do
            listen_on_relay(relay_url, deadline, state)
          end
        end
      end

      while Time.current < deadline
        threads.each do |t|
          next if t.alive?
          value = t.value rescue nil
          if value
            result = value
            break
          end
        end
        break if result
        break if threads.all? { |t| !t.alive? }
        sleep 0.2
      end

      threads.each { |thread| thread.kill if thread.alive? }
      threads.each(&:join)

      result
    end

    private

    def listen_on_relay(relay_url, deadline, state)
      backoff = 1
      socket = nil
      sub_id = nil

      while Time.current < deadline
        return nil if @lease_token && !@auth_session.renew_listener_lease!(@lease_token)
        @auth_session.reload
        return nil if @auth_session.consumed_at?
        if @auth_session.authenticated?
          return @auth_session.authenticated_user_pubkey
        end

        uri = URI.parse(relay_url)
        socket = @client.create_websocket(uri, deadline: deadline)

        unless socket
          Rails.logger.error("NIP-46 listener: failed to connect to #{relay_url}, retrying in #{backoff}s")
          sleep [backoff, deadline - Time.current].min
          backoff = [backoff * 2, 15].min
          next
        end

        Rails.logger.info("NIP-46 listener: connected to #{relay_url}")
        backoff = 1

        sub_id = "nip46-#{SecureRandom.hex(4)}"
        req = ["REQ", sub_id, { "kinds" => [24133], "#p" => [@temp_pubkey] }]
        socket.write(@client.frame_text(req.to_json))

        result = run_handshake(socket, relay_url, deadline, state)
        close_socket(socket, sub_id)
        socket = nil

        return result if result

        Rails.logger.info("NIP-46 listener: connection to #{relay_url} dropped before handshake completed, reconnecting in #{backoff}s")
        sleep [backoff, [deadline - Time.current, 0].max].min
        backoff = [backoff * 2, 15].min
      end

      nil
    rescue => e
      Rails.logger.error("NIP-46 listener error on #{relay_url}: #{e.class} - #{e.message}")
      nil
    ensure
      close_socket(socket, sub_id) if socket
    end

    # Drive both handshake phases on one socket, coordinated through `state`.
    # Returns the user pubkey on completion, or nil if the connection dropped
    # or the deadline passed (the caller reconnects and tries again).
    def run_handshake(socket, relay_url, deadline, state)
      request_sent = false

      while Time.current < deadline
        return nil if @lease_token && !@auth_session.renew_listener_lease!(@lease_token)
        @auth_session.reload
        return nil if @auth_session.consumed_at?
        return @auth_session.authenticated_user_pubkey if @auth_session.authenticated?

        # If another relay already discovered the signer, make sure we've
        # sent get_public_key on this socket too.
        if state.signer_pubkey && !request_sent
          send_get_public_key(socket, relay_url, state)
          request_sent = true
        end

        event = read_signer_event(socket, deadline)
        return nil if event.nil?    # connection dropped or deadline reached
        next if event == :idle      # no signer event this tick; re-check state

        decoded = @client.decrypt_signer_event(event)
        next unless decoded

        message = decoded[:message]
        next unless message.is_a?(Hash)

        # Phase 2: a get_public_key reply to one of our requests (on any relay).
        if state.known_request?(message["id"])
          next unless decoded[:signer_pubkey] == state.signer_pubkey

          if auth_challenge?(message)
            persist_auth_url(message["error"], message["id"])
            next
          end

          user_pubkey = extract_user_pubkey(message, relay_url)
          next unless user_pubkey
          return finalize(state.signer_pubkey, user_pubkey, relay_url)
        end

        # Phase 1: a connect response — record the signer and kick off phase 2.
        if state.signer_pubkey.nil? && @client.valid_connect_response?(message)
          signer = state.set_signer(decoded[:signer_pubkey])
          Rails.logger.info("NIP-46: valid connect response on #{relay_url} from signer #{signer[0..7]}...")
          send_get_public_key(socket, relay_url, state)
          request_sent = true
        end
      end
      nil
    end

    def send_get_public_key(socket, relay_url, state)
      request = state.request(@client)
      @auth_session.update_columns(pending_rpc_id: request[:request_id]) if @auth_session.pending_rpc_id != request[:request_id]
      socket.write(@client.frame_text(["EVENT", request[:event]].to_json))
      Rails.logger.info("NIP-46: sent get_public_key id=#{request[:request_id]} to #{state.signer_pubkey[0..7]}... via #{relay_url}")
    rescue => e
      Rails.logger.warn("NIP-46: failed to send get_public_key via #{relay_url}: #{e.class} - #{e.message}")
    end

    def auth_challenge?(message)
      message["result"] == "auth_url" && message["error"].is_a?(String)
    end

    def persist_auth_url(value, request_id)
      uri = URI.parse(value)
      return unless uri.is_a?(URI::HTTPS) && uri.host.present?
      return unless @auth_session.pending_rpc_id == request_id

      @auth_session.update!(auth_url: uri.to_s)
    rescue URI::InvalidURIError
      nil
    end

    def extract_user_pubkey(message, relay_url)
      if message["error"].present?
        Rails.logger.error("NIP-46: get_public_key error from #{relay_url}: #{message["error"]}")
        return nil
      end

      user_pubkey = message["result"]
      unless user_pubkey.is_a?(String) && user_pubkey.match?(/\A[0-9a-f]{64}\z/i)
        Rails.logger.error("NIP-46: get_public_key returned invalid pubkey: #{user_pubkey.inspect}")
        return nil
      end

      user_pubkey.downcase
    end

    def finalize(signer_pubkey, user_pubkey, relay_url)
      updated = NostrAuthSession.active.where(id: @auth_session.id, authenticated_pubkey: nil)
        .update_all(authenticated_pubkey: signer_pubkey, authenticated_user_pubkey: user_pubkey, auth_url: nil, pending_rpc_id: nil)
      return @auth_session.reload.authenticated_user_pubkey if updated.zero? && @auth_session.authenticated?
      return nil if updated.zero?
      Rails.logger.info("NIP-46: handshake complete on #{relay_url} — signer=#{signer_pubkey[0..7]}... user=#{user_pubkey[0..7]}...")
      user_pubkey
    end

    # Read one frame off the subscription. Returns the kind-24133 event hash,
    # :idle when nothing relevant arrived this tick (still connected), or nil
    # when the connection dropped or the deadline passed.
    def read_signer_event(socket, deadline)
      return nil unless Time.current < deadline

      ready = WebsocketConnection.readable_now?(socket) || IO.select([socket], nil, nil, POLL_INTERVAL)
      return :idle unless ready

      frame_deadline = [deadline, (NostrAuthSession::LISTENER_LEASE / 2).from_now].min
      data = @client.read_websocket_frame(socket, deadline: frame_deadline)
      return nil unless data

      parsed = JSON.parse(data)
      return :idle unless parsed.is_a?(Array)
      case parsed[0]
      when "EVENT"
        return :idle unless parsed[2].is_a?(Hash) && parsed[2]["kind"] == 24133
        parsed[2]
      when "OK"
        Rails.logger.info("NIP-46 listener: OK #{parsed[1..-1].inspect}")
        :idle
      when "EOSE"
        Rails.logger.info("NIP-46 listener: EOSE, waiting for real-time events...")
        :idle
      when "NOTICE"
        Rails.logger.info("NIP-46 listener: relay notice: #{parsed[1]}")
        :idle
      else
        :idle
      end
    rescue JSON::ParserError, TypeError, NoMethodError
      :idle # ignore malformed frames
    end

    def close_socket(socket, sub_id)
      socket.write(@client.frame_text(["CLOSE", sub_id].to_json)) rescue nil
      socket.close rescue nil
    end
  end
end
