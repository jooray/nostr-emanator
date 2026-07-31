# frozen_string_literal: true

require "json"
require "securerandom"

module Nostr
  # A multiplexed NIP-46 client for one Account: many concurrent requests over a
  # long-lived connection to each configured signer relay.
  #
  # WHY THIS EXISTS ALONGSIDE EventSignerService (do not merge them):
  #
  #   EventSignerService#request_signature is tuned for one latency-critical
  #   signature: it opens a socket and a subscription PER RELAY PER REQUEST and
  #   waits up to 120 s for a human to tap "approve". For a backfill of hundreds
  #   of gift wraps that is hundreds of TLS handshakes.
  #
  #   This client keeps one connection per relay for the whole session and
  #   multiplexes every request over them, with a bounded number in flight.
  #
  # WHY IT FANS OUT ACROSS RELAYS:
  #
  #   It originally pinned a single relay, to avoid multiplying the signer's
  #   inbound load. That was wrong in the way that matters. A signer subscribes to
  #   whichever relays IT chose and we cannot know which — pinning
  #   nostr.cypherpunk.today while the user's Amber sat on nos.lol and nostr.mom
  #   produced a 100% timeout rate with no error at all: the requests were
  #   published successfully to a relay nobody was listening on.
  #
  #   The protection that actually matters is MAX_IN_FLIGHT, which bounds
  #   *distinct* requests. A signer sees one request id per call however many
  #   relays carried it, so fanning out costs relay bandwidth, not signer work.
  #
  # Throughput ceiling is set by the signer, not by us: Amber sleeps at least
  # 200 ms before publishing any response (BunkerRequestUtils.retryWithBackoff),
  # so ~10-20 ops/sec is the realistic best case. MAX_IN_FLIGHT is therefore a
  # safety limit rather than a tuning knob — it costs no throughput and is what
  # stops a large backfill from wedging the user's signer.
  class Nip46Rpc
    class Error < StandardError; end
    class NotPaired < Error; end
    class Disconnected < Error; end
    class TimeoutError < Error; end

    # The signer answered with an explicit {"error": ...}. Permanent for this
    # request — a retry re-prompts the user for the same refusal.
    class SignerError < Error; end

    DEFAULT_MAX_IN_FLIGHT   = 6
    DEFAULT_REQUEST_TIMEOUT = 90
    # How long to wait on the socket before looping to flush the outbox and
    # expire abandoned requests.
    POLL_INTERVAL = 0.2
    # Once a frame starts arriving, allow this long to finish reading it. Timing
    # out mid-frame would desync the stream, so this is deliberately generous.
    FRAME_DEADLINE = 20
    RECONNECT_BACKOFF_MAX = 10
    # Only reset the backoff for a connection that actually lasted: a relay that
    # accepts and instantly drops us would otherwise be hammered into an IP ban.
    STABLE_CONNECTION = 15

    Pending = Struct.new(:id, :event, :cond, :state, :result, :error, :sent_relays, keyword_init: true)

    # One per item handed to call_many. `error` is set instead of raised so a
    # single bad item cannot sink the batch.
    Outcome = Data.define(:item, :value, :error) do
      def ok? = error.nil?
    end

    # Opens a session, yields it, and always tears it down.
    def self.open(account, **options)
      rpc = new(account, **options)
      begin
        rpc.start!
        yield rpc
      ensure
        rpc.close
      end
    end

    attr_reader :relay_url, :auth_url

    def initialize(account, max_in_flight: DEFAULT_MAX_IN_FLIGHT, request_timeout: DEFAULT_REQUEST_TIMEOUT)
      @account = account
      @max_in_flight = max_in_flight
      @request_timeout = request_timeout

      @mutex = Mutex.new
      @write_mutex = Mutex.new
      @pending = {}
      @sub_ids = {}
      @closing = false
      @auth_url = nil

      # One token per in-flight slot; `pop` blocks until a slot frees.
      @slots = Thread::Queue.new
      max_in_flight.times { |i| @slots << i }
    end

    def start!
      unless @account.signer_pubkey.present? && @account.app_privkey.present?
        raise NotPaired, "account #{@account.id} has no paired signer"
      end

      # ~29 ms of pure-Ruby secp256k1 per call and constant for the session, so
      # computing it once instead of per request matters over hundreds of calls.
      @conversation_key = Nip44.conversation_key(@account.app_privkey, @account.signer_pubkey)
      @reader = Thread.new { reader_loop }
      self
    end

    # Issue one JSON-RPC call and block for its result. Returns the signer's
    # `result` string.
    def call(method, params, timeout: @request_timeout)
      raise Disconnected, "session is closed" if closing?

      slot = @slots.pop(timeout: timeout)
      raise TimeoutError, "timed out waiting for a free request slot (#{method})" if slot.nil?

      pending = build_pending(method, params)
      begin
        @mutex.synchronize { @pending[pending.id] = pending }
        await(pending, timeout, method)
      ensure
        @mutex.synchronize { @pending.delete(pending.id) }
        @slots << slot
      end
    end

    # Run `block` once per item on a bounded pool, returning Outcomes in input
    # order.
    #
    # Each item may issue several sequential `call`s (unwrapping a gift wrap is
    # two hops); a worker holds at most one in-flight slot at a time, so pool size
    # and MAX_IN_FLIGHT cannot deadlock each other.
    #
    # The block runs on a worker thread: it must NOT hold an ActiveRecord
    # connection across a `call`. Persist in the caller, or wrap narrowly in
    # ActiveRecord::Base.connection_pool.with_connection.
    def call_many(items, concurrency: nil)
      items = items.to_a
      return [] if items.empty?

      pool_size = [ concurrency || @max_in_flight, items.size ].min
      queue = Thread::Queue.new
      items.each_with_index { |item, index| queue << [ index, item ] }
      pool_size.times { queue << nil }
      results = Array.new(items.size)

      workers = Array.new(pool_size) do
        Thread.new do
          while (job = queue.pop)
            index, item = job
            results[index] = begin
              Outcome.new(item: item, value: yield(item), error: nil)
            rescue StandardError => e
              Outcome.new(item: item, value: nil, error: e)
            end
          end
        end
      end
      workers.each(&:join)

      results
    end

    def close
      return if @mutex.synchronize { was = @closing; @closing = true; was }

      @reader&.kill
      @reader&.join(2)
      fail_all(Disconnected.new("session closed"))
    end

    def closing?
      @mutex.synchronize { @closing }
    end

    private

    def build_pending(method, params)
      request = Nip46Envelope.build_request(
        method: method,
        params: params,
        recipient_pubkey: @account.signer_pubkey,
        sender_privkey: @account.app_privkey,
        sender_pubkey: @account.app_pubkey,
        conversation_key: @conversation_key
      )

      Pending.new(
        id: request[:request_id], event: request[:event],
        cond: ConditionVariable.new, state: :queued, sent_relays: Set.new
      )
    end

    def await(pending, timeout, method)
      deadline = monotonic + timeout

      @mutex.synchronize do
        loop do
          case pending.state
          when :ok then return pending.result
          when :error then raise SignerError, "signer refused #{method}: #{pending.error.inspect}"
          when :dead then raise Disconnected, "connection lost while waiting for #{method}"
          end

          remaining = deadline - monotonic
          raise TimeoutError, "no signer response for #{method} within #{timeout}s" if remaining <= 0

          pending.cond.wait(@mutex, remaining)
        end
      end
    end

    # ---------------------------------------------------------- relay connections

    # One thread per configured signer relay.
    #
    # This used to pin a single relay, on the theory that publishing one request
    # to several relays would multiply Amber's inbound load. That was wrong in the
    # way that matters: a signer subscribes to whichever relays IT chose, and we
    # cannot know which. Pinning nostr.cypherpunk.today while the user's Amber sat
    # on nos.lol and nostr.mom produced a 100% timeout rate with no error — the
    # requests were published successfully to a relay nobody was listening on.
    #
    # EventSignerService#request_signature has always fanned out for exactly this
    # reason. The flood protection that actually matters is the in-flight cap,
    # which bounds *distinct* requests; a signer sees one request id per call
    # regardless of how many relays carried it.
    def reader_loop
      relays = EventSignerService.signing_relays
      threads = relays.map { |url| Thread.new { relay_loop(url) } }
      threads.each(&:join)
    rescue StandardError => e
      Rails.logger.error("NIP-46 RPC supervisor died: #{e.class} - #{e.message}")
    ensure
      fail_all(Disconnected.new("all signer relays closed")) unless closing?
    end

    def relay_loop(url)
      backoff = 1

      until closing?
        socket = connect(url)
        unless socket
          break if closing?
          backoff = sleep_backoff(backoff)
          next
        end

        connected_at = monotonic
        serve(url, socket)
        close_socket(url, socket)
        break if closing?

        backoff = 1 if monotonic - connected_at >= STABLE_CONNECTION
        backoff = sleep_backoff(backoff)
      end
    rescue StandardError => e
      Rails.logger.warn("NIP-46 RPC: relay #{url.inspect} failed: #{e.class} - #{e.message}")
    end

    def connect(url)
      socket = WebsocketConnection.open(URI.parse(url), deadline: 10.seconds.from_now)
      return nil unless socket

      subscribe(url, socket)
      @relay_url ||= url
      Rails.logger.info("NIP-46 RPC: connected to #{url.inspect} for account #{@account.id}")
      socket
    rescue StandardError => e
      Rails.logger.warn("NIP-46 RPC: #{url.inspect} unusable: #{e.class} - #{e.message}")
      nil
    end

    def subscribe(url, socket)
      sub_id = "rpc-#{SecureRandom.hex(4)}"
      @sub_ids[url] = sub_id
      write(socket, [ "REQ", sub_id, {
        "kinds" => [ Nip46Envelope::KIND ],
        "#p" => [ @account.app_pubkey ],
        "authors" => [ @account.signer_pubkey ],
        "since" => Time.now.to_i - 60
      } ])
    end

    def serve(url, socket)
      until closing?
        publish_unsent(url, socket)

        frame = read_one_frame(url, socket)
        return if frame == :closed
        next if frame == :idle

        handle_frame(frame)
      end
    rescue IOError, SystemCallError, OpenSSL::SSL::SSLError => e
      Rails.logger.warn("NIP-46 RPC: socket error on #{url.inspect}: #{e.class}")
    end

    # Publish any request this relay has not carried yet. Tracked per relay rather
    # than globally so a relay that connects late still picks up in-flight work,
    # and a reconnect re-publishes with the same request id (kind 24133 is
    # ephemeral, so the relay kept nothing).
    def publish_unsent(url, socket)
      due = @mutex.synchronize do
        @pending.values.reject { |p| p.sent_relays.include?(url) || %i[ok error dead].include?(p.state) }
      end

      due.each do |pending|
        write(socket, [ "EVENT", pending.event ])
        @mutex.synchronize do
          pending.sent_relays << url
          pending.state = :sent if pending.state == :queued
        end
      end
    end

    # Poll first, then read exactly one complete frame, so a quiet connection
    # never leaves us blocked mid-frame with a desynced stream. readable_now? is
    # mandatory: IO.select cannot see bytes already buffered inside OpenSSL.
    def read_one_frame(url, socket)
      unless WebsocketConnection.readable_now?(socket) || IO.select([ socket ], nil, nil, POLL_INTERVAL)
        return :idle
      end

      data = WebsocketFrameReader.read(socket, deadline: FRAME_DEADLINE.seconds.from_now)
      return :closed unless data

      begin
        JSON.parse(data)
      rescue JSON::ParserError => e
        # A garbled frame is not a dead connection.
        Rails.logger.warn("NIP-46 RPC: unparseable frame from #{url.inspect}: #{e.message}")
        :idle
      end
    rescue WebsocketFrameReader::FrameError
      :closed
    end

    def handle_frame(frame)
      case frame[0]
      when "EVENT"  then handle_event(frame[2])
      when "OK"     then handle_ok(frame)
      when "NOTICE" then Rails.logger.info("NIP-46 RPC: notice from #{@relay_url.inspect}: #{frame[1].inspect}")
      when "CLOSED" then Rails.logger.warn("NIP-46 RPC: subscription closed by #{@relay_url.inspect}: #{frame[2].inspect}")
      end
    end

    def handle_event(event)
      # Same authenticity gate as EventSignerService: right kind, actually from
      # our signer, actually addressed to our app key.
      return unless EventValidator.valid?(
        event, kind: Nip46Envelope::KIND,
        author: @account.signer_pubkey, recipient: @account.app_pubkey
      )

      plaintext = Nip46Envelope.decrypt(
        event["content"], @account.signer_pubkey, @account.app_privkey,
        context: "NIP-46 RPC response", conversation_key: @conversation_key
      )
      return unless plaintext

      response = JSON.parse(plaintext)
      return unless response.is_a?(Hash)

      # An auth_url is a nudge to open a browser, not an answer — the real
      # response follows, so leave the request pending.
      if response["result"] == "auth_url"
        record_auth_url(response["error"])
        return
      end

      @mutex.synchronize do
        pending = @pending[response["id"]]
        next unless pending

        if response["error"].present?
          pending.state = :error
          pending.error = response["error"]
        else
          pending.state = :ok
          pending.result = response["result"]
        end
        pending.cond.signal
      end
    rescue JSON::ParserError => e
      Rails.logger.warn("NIP-46 RPC: signer payload is not JSON: #{e.message}")
    end

    # A rejected request event will never reach the signer, so fail it now rather
    # than waiting out the full timeout. Only an OK naming one of our own event
    # ids is ours.
    def handle_ok(frame)
      event_id = frame[1]
      return if frame[2]

      @mutex.synchronize do
        pending = @pending.each_value.find { |p| p.event["id"] == event_id }
        next unless pending

        Rails.logger.warn("NIP-46 RPC: #{@relay_url.inspect} rejected request event: #{frame[3].inspect}")
        pending.state = :error
        pending.error = "relay rejected the request: #{frame[3]}"
        pending.cond.signal
      end
    end

    def record_auth_url(value)
      uri = URI.parse(value.to_s)
      return unless uri.is_a?(URI::HTTPS) && uri.host.present?

      @auth_url = uri.to_s
      Rails.logger.warn("NIP-46 RPC: signer wants authentication at #{uri}")
    rescue URI::InvalidURIError
      nil
    end

    def fail_all(error)
      @mutex.synchronize do
        @pending.each_value do |pending|
          next unless %i[queued sent].include?(pending.state)

          pending.state = :dead
          pending.error = error.message
          pending.cond.signal
        end
      end
    end

    def write(socket, message)
      @write_mutex.synchronize do
        WebsocketConnection.send_text(socket, JSON.generate(message), 5.seconds.from_now)
      end
    end

    def close_socket(url, socket)
      return unless socket

      sub_id = @sub_ids[url]
      @write_mutex.synchronize do
        WebsocketConnection.send_text(socket, JSON.generate([ "CLOSE", sub_id ]), 1.second.from_now) if sub_id
      rescue StandardError
        nil
      end
      socket.close
    rescue StandardError
      nil
    end

    # Interruptible so `close` does not have to wait out a long backoff.
    def sleep_backoff(backoff)
      slept = 0.0
      while slept < backoff && !closing?
        sleep 0.1
        slept += 0.1
      end
      [ backoff * 2, RECONNECT_BACKOFF_MAX ].min
    end

    def monotonic
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end
end
