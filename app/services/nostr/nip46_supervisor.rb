# frozen_string_literal: true

require "set"

module Nostr
  # Multiplexed NIP-46 login/pairing listener.
  #
  # Replaces the old one-background-job-per-login model (Nip46AuthJob +
  # Nip46Listener), which opened one WebSocket AND held one DB connection per
  # relay per login for the full 5-minute approval window. With a DB pool of
  # ~10 shared with Puma, that capped concurrent logins at 1 ("Authentication is
  # temporarily at capacity" / QR stuck on "Waiting for connection…").
  #
  # Here a single supervisor process serves EVERY pending session at once:
  #   * ONE reader thread per distinct auth relay (not per login), shared across
  #     all sessions. Each session gets its own kind-24133 subscription (one REQ,
  #     #p = that session's temp pubkey) on every relay it listed, so incoming
  #     events route back to the right session by subscription id.
  #   * A registry thread polls the DB (transiently) for active, unauthenticated
  #     sessions, adding/removing them so relay threads pick up new logins within
  #     ~1s and drop completed/expired ones.
  #   * DB connections are checked out only for the brief poll/persist operations,
  #     never held for the session lifetime — so connection use is O(1), not
  #     O(sessions × relays), and the admission cap can be raised far above 1.
  #
  # Per-session handshake logic mirrors the old Nip46Listener: validate the
  # connect secret, pin one signer, have every relay send get_public_key, and let
  # a reply on ANY relay complete the login. Reuses Nip46Client for the crypto
  # and WebSocket framing so the wire behaviour is byte-identical to the proven
  # single-session path.
  class Nip46Supervisor
    POLL_INTERVAL = 1      # seconds; registry refresh + socket read poll cadence
    IDLE_GRACE = 30        # seconds with zero pending sessions before we exit
    MAX_RUNTIME = 10 * 60  # seconds; hard cap so deploys/restarts recycle cleanly
    RECONNECT_MAX = 15     # seconds; relay reconnect backoff ceiling

    # Per-session state shared across relay threads. All mutation goes through the
    # mutex; pins one signer and one logical get_public_key request for the login.
    class Session
      attr_reader :id, :temp_pubkey, :relay_urls

      def initialize(record)
        @id = record.id
        @session_id = record.session_id
        @temp_pubkey = record.temp_pubkey
        @relay_urls = record.relay_urls
        @client = Nip46Client.new(record)
        @mutex = Mutex.new
        @signer_pubkey = nil
        @request = nil
        @done = false
      end

      attr_reader :client, :session_id

      def signer_pubkey
        @mutex.synchronize { @signer_pubkey }
      end

      def set_signer(pubkey)
        @mutex.synchronize { @signer_pubkey ||= pubkey }
      end

      def request
        @mutex.synchronize { @request ||= @client.build_request_event(@signer_pubkey, "get_public_key", []) }
      end

      def known_request?(id)
        return false unless id
        @mutex.synchronize { @request && @request[:request_id] == id }
      end

      def done?
        @mutex.synchronize { @done }
      end

      def mark_done!
        @mutex.synchronize { @done = true }
      end
    end

    # Thread-safe map of live sessions, refreshed from the DB by the main thread
    # and read by every relay thread.
    class Registry
      def initialize
        @mutex = Mutex.new
        @sessions = {} # id => Session
      end

      # Replace the live set with `records` (active, unauthenticated sessions),
      # preserving handshake state for sessions that are still present.
      def sync(records)
        @mutex.synchronize do
          incoming = records.index_by(&:id)
          # Drop sessions that are gone (authenticated/expired/consumed) or done.
          @sessions.delete_if { |id, s| !incoming.key?(id) || s.done? }
          # Add newcomers.
          incoming.each { |id, rec| @sessions[id] ||= Session.new(rec) }
        end
      end

      def relays
        @mutex.synchronize { @sessions.values.flat_map(&:relay_urls).uniq }
      end

      def for_relay(relay_url)
        @mutex.synchronize { @sessions.values.select { |s| s.relay_urls.include?(relay_url) && !s.done? } }
      end

      def empty?
        @mutex.synchronize { @sessions.empty? }
      end

      def size
        @mutex.synchronize { @sessions.size }
      end
    end

    def initialize(stop_deadline: MAX_RUNTIME)
      @stop_deadline = Time.current + stop_deadline
      @registry = Registry.new
      @relay_threads = {} # relay_url => Thread
      @stopping = false
    end

    def run
      Rails.logger.info("NIP-46 supervisor starting (until #{@stop_deadline})")
      last_active_at = Time.current

      until Time.current >= @stop_deadline || @stopping
        refresh_registry
        ensure_relay_threads

        if @registry.empty?
          break if Time.current - last_active_at > IDLE_GRACE
        else
          last_active_at = Time.current
        end

        sleep POLL_INTERVAL
      end
    rescue => e
      Rails.logger.error("NIP-46 supervisor crashed: #{e.class} - #{e.message}\n#{e.backtrace&.first(5)&.join("\n")}")
    ensure
      @stopping = true
      @relay_threads.each_value { |t| t.kill if t.alive? }
      @relay_threads.each_value(&:join)
      Rails.logger.info("NIP-46 supervisor stopped")
    end

    private

    def refresh_registry
      records = ActiveRecord::Base.connection_pool.with_connection do
        NostrAuthSession.active.where(authenticated_pubkey: nil).to_a
      end
      @registry.sync(records)
    end

    # Spawn a reader thread for every relay that has at least one live session,
    # and reap threads whose relay is no longer needed.
    def ensure_relay_threads
      needed = @registry.relays
      needed.each do |relay_url|
        t = @relay_threads[relay_url]
        next if t&.alive?
        @relay_threads[relay_url] = Thread.new { relay_loop(relay_url) }
      end
      (@relay_threads.keys - needed).each do |relay_url|
        thread = @relay_threads.delete(relay_url)
        thread&.kill
      end
    end

    # One relay: keep a socket alive, maintain one subscription per live session,
    # send get_public_key once a signer is known, and route replies back.
    def relay_loop(relay_url)
      client = Nip46Client.new(NostrAuthSession.new(relay_url: [relay_url].to_json))
      backoff = 1
      uri = URI.parse(relay_url)

      until Time.current >= @stop_deadline || @stopping
        socket = client.create_websocket(uri, deadline: @stop_deadline)
        unless socket
          Rails.logger.warn("NIP-46 supervisor: connect failed #{relay_url}, retry in #{backoff}s")
          sleep [backoff, RECONNECT_MAX].min
          backoff = [backoff * 2, RECONNECT_MAX].min
          next
        end
        Rails.logger.info("NIP-46 supervisor: connected #{relay_url}")
        backoff = 1

        serve_relay(relay_url, socket, client)
        close_socket(socket)
        sleep 0.2 # brief pause before reconnecting after a drop
      end
    rescue => e
      Rails.logger.error("NIP-46 supervisor relay #{relay_url} error: #{e.class} - #{e.message}")
    end

    # Drive one connected socket until it drops or we stop. `subs` maps
    # session_id => subscription_id (this relay only); `gpk_sent` tracks which
    # sessions we've already asked get_public_key of on this socket.
    def serve_relay(relay_url, socket, client)
      subs = {}
      gpk_sent = Set.new

      until Time.current >= @stop_deadline || @stopping
        live = @registry.for_relay(relay_url)
        live_ids = live.map(&:id)

        # Subscribe new sessions; unsubscribe gone/done ones.
        live.each do |session|
          next if subs.key?(session.id)
          sub_id = "nip46-#{SecureRandom.hex(4)}"
          req = ["REQ", sub_id, { "kinds" => [24133], "#p" => [session.temp_pubkey] }]
          socket.write(client.frame_text(req.to_json))
          subs[session.id] = sub_id
        end
        (subs.keys - live_ids).each do |gone_id|
          sub_id = subs.delete(gone_id)
          gpk_sent.delete(gone_id)
          socket.write(client.frame_text(["CLOSE", sub_id].to_json)) rescue nil
        end

        # Once a signer is pinned (by any relay), ask for the user pubkey here too.
        live.each do |session|
          next if gpk_sent.include?(session.id)
          next unless session.signer_pubkey
          send_get_public_key(socket, relay_url, session)
          gpk_sent << session.id
        end

        frame = read_frame(socket)
        return if frame == :closed
        next if frame == :idle

        handle_frame(relay_url, frame, subs)
      end
    rescue => e
      Rails.logger.warn("NIP-46 supervisor: serve #{relay_url} dropped: #{e.class} - #{e.message}")
    end

    # Route one relay frame. EVENT frames carry the sub id we opened, which maps
    # straight back to the session; hand the decrypted message to the handshake.
    def handle_frame(relay_url, frame, subs)
      return unless frame.is_a?(Array)
      case frame[0]
      when "EVENT"
        sub_id = frame[1]
        event = frame[2]
        return unless event.is_a?(Hash) && event["kind"] == 24133
        session_id = subs.key(sub_id)
        return unless session_id
        session = @registry.for_relay(relay_url).find { |s| s.id == session_id }
        return unless session
        process_event(relay_url, session, event)
      when "OK", "EOSE", "NOTICE"
        nil
      end
    end

    def process_event(relay_url, session, event)
      decoded = session.client.decrypt_signer_event(event)
      return unless decoded
      message = decoded[:message]
      return unless message.is_a?(Hash)

      if session.known_request?(message["id"])
        return unless decoded[:signer_pubkey] == session.signer_pubkey

        if auth_challenge?(message)
          persist_auth_url(session, message["error"])
          return
        end
        user_pubkey = extract_user_pubkey(message, relay_url)
        return unless user_pubkey
        finalize(session, session.signer_pubkey, user_pubkey, relay_url)
        return
      end

      if session.signer_pubkey.nil? && session.client.valid_connect_response?(message)
        signer = session.set_signer(decoded[:signer_pubkey])
        Rails.logger.info("NIP-46 supervisor: connect ok on #{relay_url} signer=#{signer[0..7]}… session=#{session.id}")
        # get_public_key is sent on the next serve_relay tick by every relay.
      end
    end

    def send_get_public_key(socket, relay_url, session)
      request = session.request
      persist_pending_rpc(session, request[:request_id])
      socket.write(session.client.frame_text(["EVENT", request[:event]].to_json))
      Rails.logger.info("NIP-46 supervisor: sent get_public_key session=#{session.id} via #{relay_url}")
    rescue => e
      Rails.logger.warn("NIP-46 supervisor: gpk send failed #{relay_url}: #{e.class} - #{e.message}")
    end

    def auth_challenge?(message)
      message["result"] == "auth_url" && message["error"].is_a?(String)
    end

    def extract_user_pubkey(message, relay_url)
      if message["error"].present?
        Rails.logger.error("NIP-46 supervisor: get_public_key error from #{relay_url}: #{message["error"]}")
        return nil
      end
      pubkey = message["result"]
      return nil unless pubkey.is_a?(String) && pubkey.match?(/\A[0-9a-f]{64}\z/i)
      pubkey.downcase
    end

    def finalize(session, signer_pubkey, user_pubkey, relay_url)
      ActiveRecord::Base.connection_pool.with_connection do
        updated = NostrAuthSession.active
          .where(id: session.id, authenticated_pubkey: nil)
          .update_all(authenticated_pubkey: signer_pubkey, authenticated_user_pubkey: user_pubkey,
            auth_url: nil, pending_rpc_id: nil)
        if updated.positive?
          Rails.logger.info("NIP-46 supervisor: handshake complete on #{relay_url} session=#{session.id} user=#{user_pubkey[0..7]}…")
        end
      end
      session.mark_done!
    end

    def persist_pending_rpc(session, request_id)
      ActiveRecord::Base.connection_pool.with_connection do
        NostrAuthSession.where(id: session.id).where.not(pending_rpc_id: request_id)
          .update_all(pending_rpc_id: request_id)
      end
    rescue => e
      Rails.logger.debug("NIP-46 supervisor: pending_rpc persist skipped: #{e.message}")
    end

    def persist_auth_url(session, value)
      uri = URI.parse(value)
      return unless uri.is_a?(URI::HTTPS) && uri.host.present?
      ActiveRecord::Base.connection_pool.with_connection do
        NostrAuthSession.active.where(id: session.id).update_all(auth_url: uri.to_s)
      end
    rescue URI::InvalidURIError
      nil
    end

    # Poll then read exactly one full frame, so we never time out mid-frame and
    # desync the stream. Returns the parsed array, :idle (nothing ready), or
    # :closed (socket dropped). Mirrors Nip46Listener#read_signer_event, and also
    # checks the SSL buffer since IO.select can miss OpenSSL-buffered frames.
    def read_frame(socket)
      ready = WebsocketConnection.readable_now?(socket) || IO.select([socket], nil, nil, POLL_INTERVAL)
      return :idle unless ready

      data = read_ws_frame(socket)
      return :closed if data.nil?

      parsed = JSON.parse(data)
      parsed.is_a?(Array) ? parsed : :idle
    rescue JSON::ParserError, TypeError, NoMethodError
      :idle
    end

    def read_ws_frame(socket)
      WebsocketFrameReader.read(socket, deadline: 20.seconds.from_now)
    rescue WebsocketFrameReader::FrameError
      nil
    end

    def close_socket(socket)
      socket.close
    rescue
      nil
    end
  end
end
