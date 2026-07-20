# frozen_string_literal: true

# Fetches latest kind 3 contact list for one account pubkey and caches the
# followed-pubkey set. Single-account granularity so one stale contact list
# doesn't block others.
class SyncContactListsJob < ApplicationJob
  queue_as :default

  def perform(pubkey_hex)
    return if pubkey_hex.blank?

    additional = Account.where(pubkey_hex: pubkey_hex).first&.write_relays || []
    fetcher = Nostr::EventFetcher.new(additional_relays: additional)

    contact_lists = fetcher.fetch_contact_lists([pubkey_hex])
    followed = contact_lists[pubkey_hex] || Set.new

    InteractionsCache.write_contact_list(pubkey_hex, followed)
  ensure
    InteractionsCache.release_inflight(:contacts, "pubkey_#{pubkey_hex}")
  end
end
