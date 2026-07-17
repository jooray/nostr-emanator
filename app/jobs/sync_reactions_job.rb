# frozen_string_literal: true

# Fetches recent kind 7 reactions authored by a given pubkey (all events,
# not filtered by target). Caches the set of liked event IDs.
class SyncReactionsJob < ApplicationJob
  queue_as :default

  def perform(pubkey_hex)
    return if pubkey_hex.blank?

    additional = Account.where(pubkey_hex: pubkey_hex).first&.write_relays || []
    fetcher = Nostr::EventFetcher.new(additional_relays: additional)

    liked = fetcher.fetch_recent_reactions(pubkey_hex)
    InteractionsCache.write_reactions(pubkey_hex, liked)
  ensure
    InteractionsCache.release_inflight(:reactions, "pubkey_#{pubkey_hex}")
  end
end
