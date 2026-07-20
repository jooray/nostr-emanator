# frozen_string_literal: true

module Nostr
  class RelayListFetcher
    TIMEOUT = 5

    def initialize
      @config = Rails.application.config_for(:emanator)
      @relays = @config.dig("nostr", "relays") || ["wss://relay.damus.io"]
    end

    # Fetch kind 10002 (NIP-65) relay list for a pubkey
    # Returns array of write relay URLs
    def fetch_write_relays(pubkey_hex)
      return [] if pubkey_hex.blank?

      @relays.each do |relay_url|
        begin
          event = fetch_relay_list_event(relay_url, pubkey_hex)
          if event
            return parse_write_relays(event)
          end
        rescue StandardError => e
          Rails.logger.warn("Failed to fetch relay list from #{relay_url}: #{e.message}")
        end
      end

      []
    end

    private

    def fetch_relay_list_event(relay_url, pubkey_hex)
      events = RelayQuery.run(
        relay_url,
        { "kinds" => [10002], "authors" => [pubkey_hex], "limit" => 1 },
        timeout: TIMEOUT,
        stop_after_first: true,
        kind: 10002,
        author: pubkey_hex
      ) { |event| event["kind"] == 10002 }

      events&.first
    end

    def parse_write_relays(event)
      return [] unless event && event["tags"]

      write_relays = []
      event["tags"].each do |tag|
        next unless tag[0] == "r" && tag[1].present?

        relay_url = tag[1]
        marker = tag[2] # "read", "write", or nil (both)

        next unless marker.nil? || marker == "write"

        # H4: a NIP-65 list is attacker-influenced data — it must never point
        # the server at loopback/private/metadata addresses. Unsafe entries are
        # dropped here so they never reach account.write_relays.
        unless Security::UrlGuard.safe_relay?(relay_url)
          Rails.logger.warn("Ignoring unsafe relay #{relay_url} from NIP-65 list")
          next
        end

        write_relays << relay_url
      end

      write_relays
    end

  end
end
