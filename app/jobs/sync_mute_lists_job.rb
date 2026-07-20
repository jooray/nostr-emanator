# frozen_string_literal: true

# Fetches kind 10000 mute lists for the login user + all managed accounts,
# unions their `p` tags, caches the union + individual events.
class SyncMuteListsJob < ApplicationJob
  queue_as :default

  def perform(user_id)
    user = User.find_by(id: user_id)
    return unless user

    pubkeys = mute_list_sources(user)
    return if pubkeys.empty?

    all_relays = collect_relays(user)
    fetcher = Nostr::EventFetcher.new(additional_relays: all_relays)

    events_by_pubkey = fetcher.fetch_mute_lists(pubkeys)

    union = Set.new
    events_by_pubkey.each do |pubkey, event|
      InteractionsCache.write_mute_event(pubkey, event)
      p_tags = (event["tags"] || []).select { |t| t[0] == "p" }.map { |t| t[1] }
      union.merge(p_tags)
    end

    InteractionsCache.write_muted_pubkeys(user, union)
  ensure
    InteractionsCache.release_inflight(:mutes, "user_#{user_id}")
  end

  private

  def mute_list_sources(user)
    ([user.pubkey_hex] + user.accounts.pluck(:pubkey_hex)).compact.uniq
  end

  def collect_relays(user)
    user.accounts.flat_map { |a| a.write_relays || [] }.compact.uniq
  end
end
