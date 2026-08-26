# frozen_string_literal: true

module Nostr
  # Live inbound gift-wrap subscriptions for every messaging-enabled account.
  #
  # Structurally a sibling of Nip46Supervisor: one thread per connection, DB
  # connections checked out only transiently, a bounded runtime so the process is
  # recycled, and a backoff that only resets for connections that actually lasted.
  #
  # Two things differ from that supervisor, both forced by NIP-42:
  #
  #   * A socket that authenticates is bound to ONE pubkey, so an auth-requiring
  #     relay needs a socket per (account, relay). Relays that do not demand auth
  #     share one socket with a subscription per account, which is the common case
  #     and keeps the thread count sane.
  #   * MAX_RUNTIME is long (55 min, not 10) precisely so the cost of that
  #     authentication is amortised rather than paid every few minutes.
  #
  # This never decrypts. Decryption needs the signer — 200 ms minimum per call and
  # up to 120 s if a human has to tap — and blocking here would stop us reading the
  # socket and silently drop events. Wraps are recorded and DecryptGiftWrapsJob is
  # woken instead.
  class DmSupervisor
    POLL_INTERVAL = 1
    REGISTRY_REFRESH = 15.seconds
    MAX_RUNTIME = 55.minutes
    RECONNECT_MAX = 15
    STABLE_CONNECTION = 15
    IDLE_GRACE = 30.seconds
    # Waking the decrypt job on every single wrap would enqueue a job per message
    # during a burst; the in-flight guard already dedupes, this just avoids churn.
    WAKE_DEBOUNCE = 5.seconds
    # Relays that want NIP-42 send the challenge unprompted on connect, so this is
    # a generous ceiling rather than an expected wait.
    CHALLENGE_TIMEOUT = 3.seconds
    # How long to idle a connection whose accounts we already know cannot
    # authenticate here. RelayAuth caches the rejection for hours; this just needs
    # to be long enough that the retry is not abusive to a third-party relay.
    REJECTED_RETRY_INTERVAL = 5.minutes

    Target = Struct.new(:account_id, :pubkey_hex, :relay_url, :requires_auth, keyword_init: true) do
      # Auth binds a socket to one pubkey, so those cannot be shared.
      def key = requires_auth ? "#{relay_url}|#{account_id}" : relay_url
    end

    def initialize(stop_deadline: MAX_RUNTIME.from_now)
      @stop_deadline = stop_deadline
      @stopping = false
      @threads = {}
      @targets = {}
      @mutex = Mutex.new
      @last_wake = {}
    end

    def stop! = @stopping = true

    def run
      Rails.logger.info("DM supervisor starting (until #{@stop_deadline})")
      last_active_at = Time.current
      last_refresh = Time.at(0)

      until finished?
        if Time.current - last_refresh >= REGISTRY_REFRESH
          refresh_targets
          last_refresh = Time.current
        end
        ensure_threads

        if @mutex.synchronize { @targets.empty? }
          break if Time.current - last_active_at > IDLE_GRACE
        else
          last_active_at = Time.current
        end

        sleep POLL_INTERVAL
      end
    rescue StandardError => e
      Rails.logger.error("DM supervisor crashed: #{e.class} - #{e.message}\n#{e.backtrace&.first(5)&.join("\n")}")
    ensure
      @stopping = true
      @threads.each_value { |t| t.kill if t.alive? }
      @threads.each_value { |t| t.join(2) }
      Rails.logger.info("DM supervisor stopped")
    end

    private

    def finished? = Time.current >= @stop_deadline || @stopping

    def refresh_targets
      grouped = ActiveRecord::Base.connection_pool.with_connection do
        service = DmRelayListService.new
        Account.messaging.flat_map do |account|
          next [] unless account.messaging_capable?

          service.inbox_relays_for(account).map do |relay_url|
            Target.new(
              account_id: account.id, pubkey_hex: account.pubkey_hex,
              relay_url: relay_url, requires_auth: RelayAuth.requires_auth?(relay_url)
            )
          end
        end.group_by(&:key)
      end

      @mutex.synchronize { @targets = grouped }
    rescue StandardError => e
      Rails.logger.error("DM supervisor could not refresh targets: #{e.message}")
    end

    def ensure_threads
      wanted = @mutex.synchronize { @targets.keys }

      wanted.each do |key|
        thread = @threads[key]
        next if thread&.alive?

        @threads[key] = Thread.new { connection_loop(key) }
      end

      (@threads.keys - wanted).each { |key| @threads.delete(key)&.kill }
    end

    def connection_loop(key)
      backoff = 1

      until finished?
        targets = @mutex.synchronize { @targets[key] }
        break if targets.blank?

        relay_url = targets.first.relay_url

        # Every account on this connection is already known to be unauthenticable
        # here, so connecting would only repeat a handshake we know fails. Short-
        # circuiting the auth attempt alone was not enough: the socket was still
        # opened every backoff cycle. Idle until the rejection cache expires.
        if targets.all? { |t| t.requires_auth && RelayAuth.rejected?(relay_url, t.pubkey_hex) }
          sleep_quietly(REJECTED_RETRY_INTERVAL)
          next
        end

        socket = WebsocketConnection.open(URI.parse(relay_url), deadline: 15.seconds.from_now)

        unless socket
          backoff = sleep_backoff(backoff)
          next
        end

        connected_at = Time.current
        subscribed = serve(relay_url, socket, targets)
        close_socket(socket)

        # Only a connection that actually carried a subscription counts as
        # working. Without this a relay we cannot authenticate to looked like a
        # healthy long connection — the auth attempt itself takes longer than
        # STABLE_CONNECTION — so the backoff reset every round and the supervisor
        # reconnected every ~16s forever, hammering a third-party relay.
        backoff = 1 if subscribed && Time.current - connected_at >= STABLE_CONNECTION
        break if finished?
        backoff = sleep_backoff(backoff)
      end
    rescue StandardError => e
      Rails.logger.error("DM supervisor connection #{key.inspect} failed: #{e.class} - #{e.message}")
    end

    # One socket. Subscribes each account it carries, authenticating first when
    # the relay demands it, then routes gift wraps into the ledger.
    #
    # Returns whether anything was actually subscribed, so the caller can tell a
    # working connection from one that connected and achieved nothing.
    def serve(relay_url, socket, targets)
      subs = {}

      targets.each do |target|
        if target.requires_auth && !authenticate(socket, relay_url, target)
          Rails.logger.warn("DM supervisor: could not authenticate #{target.pubkey_hex.first(12)} to #{relay_url.inspect}")
          next
        end

        subs[subscribe(socket, target)] = target
      end

      return false if subs.empty?

      until finished?
        frame = read_frame(socket)
        return true if frame == :closed
        next if frame == :idle

        handle(frame, subs, relay_url, socket)
      end

      true
    rescue IOError, SystemCallError, OpenSSL::SSL::SSLError => e
      Rails.logger.info("DM supervisor: socket closed on #{relay_url.inspect} (#{e.class})")
      subs.present?
    end

    def subscribe(socket, target)
      sub_id = "dm-#{SecureRandom.hex(4)}"
      since = ActiveRecord::Base.connection_pool.with_connection do
        DmSyncState.for_account(Account.find(target.account_id)).since
      end

      write(socket, [ "REQ", sub_id, {
        "kinds" => [ Nip17::WRAP_KIND ], "#p" => [ target.pubkey_hex ], "since" => since
      } ])
      sub_id
    end

    def handle(frame, subs, relay_url, socket)
      case frame[0]
      when "EVENT"
        target = subs[frame[1]]
        record(target, frame[2]) if target
      when "CLOSED"
        # The subscription is gone. Reconnecting is simpler and safer than trying
        # to re-authenticate in place, and the outer loop backs off.
        Rails.logger.warn("DM supervisor: #{relay_url.inspect} closed a subscription: #{frame[2].inspect}")
        raise IOError, "subscription closed"
      when "AUTH"
        # A challenge arriving mid-session means the relay wants us to
        # re-authenticate. Drop the connection and let the loop reconnect, which
        # runs the handshake from the top — simpler than re-authenticating in
        # place, and it cannot race another thread's handshake.
        Rails.logger.info("DM supervisor: #{relay_url.inspect} re-challenged; reconnecting")
        raise IOError, "relay re-challenged"
      when "NOTICE"
        Rails.logger.info("DM supervisor: notice from #{relay_url.inspect}: #{frame[1].inspect}")
      end
    end

    # Fast path only: validate, store, wake the decrypt job. Never blocks on the
    # signer.
    def record(target, event)
      return unless Nip17.valid_wrap?(event, recipient_pubkey: target.pubkey_hex)

      ActiveRecord::Base.connection_pool.with_connection do
        wrap = GiftWrap.create_or_find_by!(account_id: target.account_id, wrap_id: event["id"]) do |record|
          record.wrap_created_at = Time.at(event["created_at"].to_i).utc
          record.seen_at = Time.current
          record.wrap_event = event
          record.relays = [ target.relay_url ]
        end

        if wrap.previously_new_record?
          wake_decryptor(target.account_id)
        else
          # The same wrap reaches us from every relay we hold a subscription on.
          # Each extra sighting is another relay this peer's client publishes to,
          # which is exactly what a reply wants to know.
          wrap.observed_on!(target.relay_url)
        end
      end
    rescue ActiveRecord::RecordNotUnique
      nil
    rescue StandardError => e
      Rails.logger.warn("DM supervisor could not record a wrap: #{e.message}")
    end

    # Guarded: several connection threads can be recording wraps for the same
    # account at once.
    def wake_decryptor(account_id)
      due = @mutex.synchronize do
        last = @last_wake[account_id]
        next false if last && Time.current - last < WAKE_DEBOUNCE

        @last_wake[account_id] = Time.current
        true
      end

      DecryptGiftWrapsJob.perform_later(account_id) if due
    end

    def authenticate(socket, relay_url, target)
      return false if RelayAuth.rejected?(relay_url, target.pubkey_hex)

      # LOCAL, not an instance variable. There is one connection thread per relay
      # (per account, where auth is needed) and they all share this object, so a
      # shared @challenge meant threads clobbered each other's: one starting its
      # handshake reset the value another was about to sign, and whichever relay
      # answered last overwrote the rest. The result was authentication failing
      # against a relay that, probed on its own, works perfectly.
      challenge = nil
      deadline = CHALLENGE_TIMEOUT.from_now
      # `finished?` too, so a shutdown is not held up waiting on a relay that is
      # never going to send one.
      while challenge.nil? && Time.current < deadline && !finished?
        frame = read_frame(socket)
        break if frame == :closed
        next if frame == :idle

        challenge = frame[1] if frame[0] == "AUTH"
      end

      # Every failure below is remembered, not just a refused signature. Bailing
      # out here without recording it meant a relay that never sent a challenge
      # was retried on every single reconnect, forever.
      if challenge.nil?
        RelayAuth.remember_result!(relay_url, target.pubkey_hex, :rejected)
        return false
      end

      signed = ActiveRecord::Base.connection_pool.with_connection do
        account = Account.find(target.account_id)
        unsigned = RelayAuth.build_unsigned(
          relay_url: relay_url, challenge: challenge, pubkey: account.pubkey_hex
        )
        EventSignerService.new.request_signature(account, unsigned)
      end

      unless signed
        RelayAuth.remember_result!(relay_url, target.pubkey_hex, :rejected)
        return false
      end

      write(socket, [ "AUTH", signed ])
      RelayAuth.remember_result!(relay_url, target.pubkey_hex, :ok)
      ActiveRecord::Base.connection_pool.with_connection do
        Account.find(target.account_id).clear_relay_auth_blocked!(RelayAuth.host(relay_url))
      end
      true
    rescue StandardError => e
      Rails.logger.warn("DM supervisor authentication failed on #{relay_url.inspect}: #{e.message}")
      RelayAuth.remember_result!(relay_url, target.pubkey_hex, :rejected)
      false
    end

    # Poll, then read exactly one complete frame, so a quiet connection never
    # leaves us blocked mid-frame with a desynced stream. readable_now? is
    # mandatory: IO.select cannot see bytes buffered inside OpenSSL.
    def read_frame(socket)
      unless WebsocketConnection.readable_now?(socket) || IO.select([ socket ], nil, nil, POLL_INTERVAL)
        return :idle
      end

      data = WebsocketFrameReader.read(socket, deadline: 20.seconds.from_now)
      return :closed unless data

      JSON.parse(data)
    rescue JSON::ParserError
      :idle
    rescue WebsocketFrameReader::FrameError
      :closed
    end

    def write(socket, message)
      WebsocketConnection.send_text(socket, JSON.generate(message), 5.seconds.from_now)
    end

    def close_socket(socket)
      socket&.close
    rescue StandardError
      nil
    end

    def sleep_backoff(backoff)
      sleep_quietly(backoff)
      [ backoff * 2, RECONNECT_MAX ].min
    end

    # Interruptible, so a shutdown is never held up by a long idle.
    def sleep_quietly(seconds)
      slept = 0.0
      while slept < seconds && !finished?
        sleep 0.2
        slept += 0.2
      end
    end
  end
end
