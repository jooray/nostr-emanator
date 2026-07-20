# frozen_string_literal: true

module Nostr
  class EventPublisherService
    PUBLISH_TIMEOUT = 10

    # M9: publishing used to walk the relay list sequentially and unbounded — a
    # relay list of 50 (it comes from an account's NIP-65 list, which we do not
    # control) meant up to 50 × PUBLISH_TIMEOUT on one worker. The list is now
    # capped and the relays are published to concurrently.
    MAX_RELAYS = 8

    def initialize
      @config = Rails.application.config_for(:emanator)
      @default_relays = @config.dig("nostr", "relays") || []
    end

    # Publish a pre-signed event to relays
    # Returns hash of { relay_url => :ok/:error }
    def publish(signed_event, relays: [])
      all_relays = select_relays(relays)
      results = {}
      mutex = Mutex.new

      threads = all_relays.map do |relay_url|
        Thread.new do
          begin
            result = publish_to_relay(relay_url, signed_event)
            Rails.logger.info("Published to #{relay_url}: #{result}")
          rescue StandardError => e
            result = :error
            Rails.logger.warn("Failed to publish to #{relay_url}: #{e.message}")
          end
          mutex.synchronize { results[relay_url] = result }
        end
      end

      threads.each(&:join)

      # Keep the original relay order in the results hash (the UI lists them).
      all_relays.index_with { |relay_url| results[relay_url] }.compact
    end

    private

    # H4/M9: drop relays we must not connect to (private/loopback/metadata
    # hosts, plaintext ws:// in production — those URLs come from unverified
    # NIP-65 lists and user settings) and cap how many we fan out to. The
    # configured defaults are kept if the account's own list already fills the
    # cap, so a poisoned list cannot push us off our known-good relays.
    def select_relays(relays)
      account_relays = Array(relays).select { |url| safe_relay?(url) }
      default_relays = @default_relays.select { |url| safe_relay?(url) }
      reserved = [ default_relays.size, MAX_RELAYS / 2 ].min

      (account_relays.first(MAX_RELAYS - reserved) + default_relays).uniq.first(MAX_RELAYS)
    end

    def safe_relay?(url)
      return true if Security::UrlGuard.safe_relay?(url)

      Rails.logger.warn("Skipping unsafe relay #{url}")
      false
    end

    # Publish and wait for the relay's OK. All socket I/O goes through
    # WebsocketConnection / WebsocketFrameReader: verified TLS, bounded frames
    # and every read enforced against the PUBLISH_TIMEOUT deadline, so a relay
    # that accepts the connection then goes silent can no longer wedge a worker.
    def publish_to_relay(relay_url, signed_event)
      uri = URI.parse(relay_url)
      deadline = PUBLISH_TIMEOUT.seconds.from_now
      socket = WebsocketConnection.open(uri, deadline: deadline)
      return :error unless socket

      begin
        WebsocketConnection.send_text(socket, ["EVENT", signed_event].to_json, deadline)

        while Time.current < deadline
          ready = WebsocketConnection.readable_now?(socket) ||
            IO.select([socket], nil, nil, WebsocketConnection.select_timeout(deadline))
          next unless ready

          data = read_websocket_frame(socket, deadline)
          break unless data

          begin
            parsed = JSON.parse(data)
            if parsed[0] == "OK"
              # Only an OK for the event we just published answers this publish.
              next unless parsed[1] == signed_event["id"] || parsed[1] == signed_event[:id]
              return parsed[2] ? :ok : :rejected
            elsif parsed[0] == "NOTICE"
              Rails.logger.warn("Relay notice from #{relay_url}: #{parsed[1]}")
            end
          rescue JSON::ParserError
            next
          end
        end

        :timeout
      ensure
        socket.close rescue nil
      end
    end

    def read_websocket_frame(socket, deadline)
      WebsocketFrameReader.read(socket, deadline: deadline)
    rescue WebsocketFrameReader::FrameError => e
      Rails.logger.warn("Relay frame error: #{e.message}")
      nil
    end
  end
end
