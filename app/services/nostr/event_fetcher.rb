# frozen_string_literal: true

require "json"
require "socket"
require "openssl"
require "base64"
require "securerandom"

module Nostr
  class EventFetcher
    TIMEOUT = 5

    KIND_SHORT_TEXT = 1
    KIND_REPOST = 6
    KIND_MUTE_LIST = 10000

    def initialize(additional_relays: [])
      @config = Rails.application.config_for(:emanator)
      global_relays = @config.dig("nostr", "relays") || ["wss://relay.damus.io"]
      @relays = (global_relays + Array(additional_relays)).map { |r| r.chomp("/") }.uniq
    end

    # Fetch specific events by their IDs
    def fetch_by_ids(event_ids)
      return [] if event_ids.blank?

      filter = {
        "ids" => event_ids,
        "limit" => event_ids.size
      }

      threads = @relays.map do |relay_url|
        Thread.new do
          fetch_from_relay(relay_url, filter)
        rescue StandardError => e
          Rails.logger.warn("Failed to fetch events by ID from #{relay_url}: #{e.message}")
          []
        end
      end

      all_events = threads.flat_map(&:value)

      # Dedupe by event ID
      events_by_id = {}
      all_events.each do |event|
        events_by_id[event["id"]] ||= event
      end

      events_by_id
    end

    # Fetch events that mention/tag a pubkey (replies, quotes, mentions)
    # Uses "#p" filter instead of "authors" to find events by others
    def fetch_mentions(pubkey_hex, options = {})
      since_ts = options[:since].is_a?(Time) ? options[:since].to_i : options[:since]
      limit = options[:limit] || 50

      filter = {
        "kinds" => [KIND_SHORT_TEXT],
        "#p" => [pubkey_hex],
        "limit" => limit
      }
      filter["since"] = since_ts if since_ts

      threads = @relays.map do |relay_url|
        Thread.new do
          events = fetch_from_relay(relay_url, filter)
          events.each { |event| event["_seen_on_relays"] = [relay_url] }
          events
        rescue StandardError => e
          Rails.logger.warn("Failed to fetch mentions from #{relay_url}: #{e.message}")
          []
        end
      end

      all_events = threads.flat_map(&:value)

      # Dedupe by event ID, exclude events by the account itself
      events_by_id = {}
      all_events.each do |event|
        next if event["pubkey"] == pubkey_hex

        if events_by_id[event["id"]]
          existing_relays = events_by_id[event["id"]]["_seen_on_relays"] || []
          new_relays = event["_seen_on_relays"] || []
          events_by_id[event["id"]]["_seen_on_relays"] = (existing_relays + new_relays).uniq
          next
        end

        events_by_id[event["id"]] = event
      end

      events_by_id.values.sort_by { |e| -e["created_at"] }
    end

    # Fetch events that mention/tag ANY of the given pubkeys (combined filter + parallel relays)
    def fetch_mentions_combined(pubkey_hexes, options = {})
      pubkey_hexes = Array(pubkey_hexes).compact.uniq
      return [] if pubkey_hexes.empty?

      since_ts = options[:since].is_a?(Time) ? options[:since].to_i : options[:since]
      limit = options[:limit] || 50

      # Scale relay limit with account count so less popular accounts aren't crowded out
      relay_limit = [limit, limit * pubkey_hexes.size].max

      filter = {
        "kinds" => [KIND_SHORT_TEXT],
        "#p" => pubkey_hexes,
        "limit" => relay_limit
      }
      filter["since"] = since_ts if since_ts

      # Query all relays in parallel
      threads = @relays.map do |relay_url|
        Thread.new do
          events = fetch_from_relay(relay_url, filter)
          events.each do |event|
            event["_seen_on_relays"] = [relay_url]
          end
          events
        rescue StandardError => e
          Rails.logger.warn("Failed to fetch combined mentions from #{relay_url}: #{e.message}")
          []
        end
      end

      all_events = threads.flat_map(&:value)

      # Dedupe by event ID, exclude self-authored events
      events_by_id = {}
      all_events.each do |event|
        next if pubkey_hexes.include?(event["pubkey"])

        if events_by_id[event["id"]]
          existing_relays = events_by_id[event["id"]]["_seen_on_relays"] || []
          new_relays = event["_seen_on_relays"] || []
          events_by_id[event["id"]]["_seen_on_relays"] = (existing_relays + new_relays).uniq
          next
        end

        events_by_id[event["id"]] = event
      end

      events_by_id.values.sort_by { |e| -e["created_at"] }
    end

    # Streaming version: yields accumulated events after each relay completes
    def fetch_mentions_combined_streaming(pubkey_hexes, options = {}, &on_relay_complete)
      pubkey_hexes = Array(pubkey_hexes).compact.uniq
      return [] if pubkey_hexes.empty?

      since_ts = options[:since].is_a?(Time) ? options[:since].to_i : options[:since]
      limit = options[:limit] || 50

      # Scale relay limit with account count so less popular accounts aren't crowded out
      relay_limit = [limit, limit * pubkey_hexes.size].max

      filter = {
        "kinds" => [KIND_SHORT_TEXT],
        "#p" => pubkey_hexes,
        "limit" => relay_limit
      }
      filter["since"] = since_ts if since_ts

      mutex = Mutex.new
      events_by_id = {}

      threads = @relays.map do |relay_url|
        Thread.new do
          relay_events = fetch_from_relay(relay_url, filter)

          mutex.synchronize do
            relay_events.each do |event|
              next if pubkey_hexes.include?(event["pubkey"])

              event["_seen_on_relays"] = [relay_url]

              if events_by_id[event["id"]]
                existing_relays = events_by_id[event["id"]]["_seen_on_relays"] || []
                events_by_id[event["id"]]["_seen_on_relays"] = (existing_relays + [relay_url]).uniq
              else
                events_by_id[event["id"]] = event
              end
            end

            if on_relay_complete
              snapshot = events_by_id.values.sort_by { |e| -e["created_at"] }
              on_relay_complete.call(snapshot)
            end
          end
        rescue StandardError => e
          Rails.logger.warn("Failed to fetch streaming mentions from #{relay_url}: #{e.message}")
        end
      end

      threads.each(&:join)
      events_by_id.values.sort_by { |e| -e["created_at"] }
    end

    # Fetch kind 3 contact lists for multiple pubkeys
    # Returns: { pubkey_hex => Set[followed_pubkeys] }
    def fetch_contact_lists(pubkey_hexes)
      pubkey_hexes = Array(pubkey_hexes).compact.uniq
      return {} if pubkey_hexes.empty?

      filter = {
        "authors" => pubkey_hexes,
        "kinds" => [3],
        "limit" => pubkey_hexes.size
      }

      threads = @relays.map do |relay_url|
        Thread.new do
          fetch_from_relay(relay_url, filter)
        rescue StandardError => e
          Rails.logger.warn("Failed to fetch contact lists from #{relay_url}: #{e.message}")
          []
        end
      end

      all_events = threads.flat_map(&:value)

      # Keep latest kind 3 per pubkey (highest created_at)
      latest_by_pubkey = {}
      all_events.each do |event|
        pubkey = event["pubkey"]
        if latest_by_pubkey[pubkey].nil? || event["created_at"] > latest_by_pubkey[pubkey]["created_at"]
          latest_by_pubkey[pubkey] = event
        end
      end

      # Extract followed pubkeys into Sets
      result = {}
      latest_by_pubkey.each do |pubkey, event|
        p_tags = (event["tags"] || []).select { |t| t[0] == "p" }.map { |t| t[1] }
        result[pubkey] = Set.new(p_tags)
      end

      result
    end

    # Fetch latest kind 10000 mute list per pubkey.
    # Returns: { pubkey_hex => event_hash } (most recent per pubkey).
    def fetch_mute_lists(pubkey_hexes)
      pubkey_hexes = Array(pubkey_hexes).compact.uniq
      return {} if pubkey_hexes.empty?

      filter = {
        "authors" => pubkey_hexes,
        "kinds" => [KIND_MUTE_LIST],
        "limit" => pubkey_hexes.size
      }

      threads = @relays.map do |relay_url|
        Thread.new do
          fetch_from_relay(relay_url, filter)
        rescue StandardError => e
          Rails.logger.warn("Failed to fetch mute lists from #{relay_url}: #{e.message}")
          []
        end
      end

      all_events = threads.flat_map(&:value)

      latest_by_pubkey = {}
      all_events.each do |event|
        pubkey = event["pubkey"]
        if latest_by_pubkey[pubkey].nil? || event["created_at"] > latest_by_pubkey[pubkey]["created_at"]
          latest_by_pubkey[pubkey] = event
        end
      end

      latest_by_pubkey
    end

    # Fetch recent reactions authored by a single pubkey (no event-id filter).
    # Returns: Set<liked_event_id>.
    def fetch_recent_reactions(pubkey_hex, limit: 500)
      return Set.new if pubkey_hex.blank?

      filter = {
        "kinds" => [7],
        "authors" => [pubkey_hex],
        "limit" => limit
      }

      threads = @relays.map do |relay_url|
        Thread.new do
          fetch_from_relay(relay_url, filter)
        rescue StandardError => e
          Rails.logger.warn("Failed to fetch recent reactions from #{relay_url}: #{e.message}")
          []
        end
      end

      all_events = threads.flat_map(&:value)

      seen_ids = Set.new
      result = Set.new
      all_events.each do |event|
        next if seen_ids.include?(event["id"])
        seen_ids << event["id"]

        e_tag = (event["tags"] || []).find { |t| t[0] == "e" }
        result << e_tag[1] if e_tag
      end

      result
    end

    # Fetch kind 7 reactions by specific authors for specific events
    # Returns: Set[[author_pubkey, liked_event_id]] pairs
    def fetch_reactions(author_pubkeys, event_ids)
      author_pubkeys = Array(author_pubkeys).compact.uniq
      event_ids = Array(event_ids).compact.uniq
      return Set.new if author_pubkeys.empty? || event_ids.empty?

      filter = {
        "kinds" => [7],
        "authors" => author_pubkeys,
        "#e" => event_ids,
        "limit" => event_ids.size * author_pubkeys.size
      }

      threads = @relays.map do |relay_url|
        Thread.new do
          fetch_from_relay(relay_url, filter)
        rescue StandardError => e
          Rails.logger.warn("Failed to fetch reactions from #{relay_url}: #{e.message}")
          []
        end
      end

      all_events = threads.flat_map(&:value)

      # Dedupe and extract author+event pairs
      seen_ids = Set.new
      result = Set.new
      all_events.each do |event|
        next if seen_ids.include?(event["id"])
        seen_ids << event["id"]

        e_tag = (event["tags"] || []).find { |t| t[0] == "e" }
        next unless e_tag

        result << [event["pubkey"], e_tag[1]]
      end

      result
    end

    def fetch(pubkey_hex, options = {})
      kinds = options[:kinds] || [KIND_SHORT_TEXT]
      kinds << KIND_REPOST if options[:include_reposts] && !kinds.include?(KIND_REPOST)

      since_ts = options[:since].is_a?(Time) ? options[:since].to_i : options[:since]
      until_ts = options[:until_time].is_a?(Time) ? options[:until_time].to_i : options[:until_time]
      limit = options[:limit] || 50

      filter = {
        "authors" => [pubkey_hex],
        "kinds" => kinds.uniq,
        "limit" => limit
      }
      filter["since"] = since_ts if since_ts
      filter["until"] = until_ts if until_ts

      threads = @relays.map do |relay_url|
        Thread.new do
          events = fetch_from_relay(relay_url, filter)
          events.each { |event| event["_seen_on_relays"] = [relay_url] }
          events
        rescue StandardError => e
          Rails.logger.warn("Failed to fetch from #{relay_url}: #{e.message}")
          []
        end
      end

      all_events = threads.flat_map(&:value)

      # Dedupe by event ID and filter replies
      events_by_id = {}
      all_events.each do |event|
        if events_by_id[event["id"]]
          existing_relays = events_by_id[event["id"]]["_seen_on_relays"] || []
          new_relays = event["_seen_on_relays"] || []
          events_by_id[event["id"]]["_seen_on_relays"] = (existing_relays + new_relays).uniq
          next
        end

        unless options[:include_replies]
          next if event["tags"]&.any? { |t| t[0] == "e" }
        end

        events_by_id[event["id"]] = event
      end

      events_by_id.values.sort_by { |e| -e["created_at"] }
    end

    private

    # H3: RelayQuery verifies each event's id + Schnorr signature and checks it
    # against the kinds/authors of this filter, so forged or spoofed events
    # never reach the callers above (mentions, contact lists, mute lists…).
    def fetch_from_relay(relay_url, filter)
      RelayQuery.run(relay_url, filter, timeout: TIMEOUT) || []
    end
  end
end
