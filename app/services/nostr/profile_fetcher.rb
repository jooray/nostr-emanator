# frozen_string_literal: true

require "json"
require "socket"
require "openssl"
require "base64"
require "securerandom"

module Nostr
  class ProfileFetcher
    TIMEOUT = 5

    def initialize(additional_relays: [])
      @config = Rails.application.config_for(:emanator)
      global_relays = @config.dig(:nostr, :relays) || ["wss://relay.damus.io", "wss://nos.lol"]
      @relays = (global_relays + Array(additional_relays)).map { |r| r.chomp("/") }.uniq
    end

    def fetch(pubkey_hex)
      return nil if pubkey_hex.blank?

      @relays.each do |relay_url|
        begin
          event = fetch_from_relay(relay_url, pubkey_hex)
          if event
            profile = parse_profile(event)
            return profile if profile
          end
        rescue StandardError => e
          Rails.logger.warn("Failed to fetch profile from #{relay_url}: #{e.message}")
        end
      end

      nil
    end

    # The whole kind-0 event, not the four fields `fetch` parses out.
    #
    # Editing a profile has to merge over everything already there: a kind 0 is
    # replaceable, so publishing a rebuilt one silently destroys every field
    # this app does not model (nip05, lud16, a client's own extensions). The
    # created_at comes back too, so the replacement can be stamped strictly
    # later than what is live.
    #
    # Takes the NEWEST event across relays rather than the first responder —
    # relays disagree, and an older copy would merge stale values back in.
    def fetch_raw_event(pubkey_hex)
      return nil if pubkey_hex.blank?

      newest = nil
      @relays.each do |relay_url|
        begin
          event = fetch_from_relay(relay_url, pubkey_hex)
          next unless event.is_a?(Hash) && event["content"].is_a?(String)

          newest = event if newest.nil? || event["created_at"].to_i > newest["created_at"].to_i
        rescue StandardError => e
          Rails.logger.warn("Failed to fetch raw profile from #{relay_url}: #{e.message}")
        end
      end

      newest
    end

    # Fetch profiles for multiple pubkeys in a single batch (parallel relays)
    def fetch_batch(pubkey_hexes)
      pubkey_hexes = Array(pubkey_hexes).compact.uniq
      return {} if pubkey_hexes.empty?

      filter = { "kinds" => [0], "authors" => pubkey_hexes }

      # Query all relays in parallel
      threads = @relays.map do |relay_url|
        Thread.new do
          begin
            fetch_events_from_relay(relay_url, filter)
          rescue StandardError => e
            Rails.logger.warn("Failed to batch fetch profiles from #{relay_url}: #{e.message}")
            []
          end
        end
      end

      all_events = threads.flat_map(&:value)

      # Dedupe by pubkey, keep most recent event per pubkey
      latest_by_pubkey = {}
      all_events.each do |event|
        pk = event["pubkey"]
        if latest_by_pubkey[pk].nil? || event["created_at"].to_i > latest_by_pubkey[pk]["created_at"].to_i
          latest_by_pubkey[pk] = event
        end
      end

      # Parse profiles
      result = {}
      latest_by_pubkey.each do |pk, event|
        profile = parse_profile(event)
        result[pk] = profile if profile
      end
      result
    end

    private

    # Fetch multiple events from a relay (used by fetch_batch)
    def fetch_events_from_relay(relay_url, filter)
      # H3: kind + signature verified inside RelayQuery (authors come from the
      # filter, so a forged profile for another pubkey is dropped there).
      RelayQuery.run(relay_url, filter, timeout: TIMEOUT, kind: 0) || []
    end

    def fetch_from_relay(relay_url, pubkey_hex)
      events = RelayQuery.run(
        relay_url,
        { "kinds" => [0], "authors" => [pubkey_hex], "limit" => 1 },
        timeout: TIMEOUT,
        stop_after_first: true,
        kind: 0,
        author: pubkey_hex
      ) { |event| event["kind"] == 0 }

      events&.first
    end

    def parse_profile(event)
      return nil unless event && event["content"]

      profile_data = JSON.parse(event["content"])

      {
        display_name: profile_data["display_name"] || profile_data["displayName"] || profile_data["name"],
        username: profile_data["name"] || profile_data["username"],
        about: profile_data["about"],
        picture: profile_data["picture"]
      }
    rescue JSON::ParserError
      nil
    end

  end
end
