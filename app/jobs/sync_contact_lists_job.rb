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

    changed = InteractionsCache.read_contact_list(pubkey_hex) != followed
    InteractionsCache.write_contact_list(pubkey_hex, followed)

    # A new follow can promote a waiting message request to the main inbox — and
    # under the cross-account rule, a follow by one account promotes the sender
    # for every other account this user manages. Only on an actual change: this
    # runs on staleness, not on edits.
    reclassify(pubkey_hex) if changed
  ensure
    InteractionsCache.release_inflight(:contacts, "pubkey_#{pubkey_hex}")
  end

  private

  # The contact list belongs to one pubkey, which may be a managed account or the
  # login identity itself; both feed the sibling-follow rule.
  def reclassify(pubkey_hex)
    user_ids = Account.where(pubkey_hex: pubkey_hex).pluck(:user_id)
    user_ids |= User.where(pubkey_hex: pubkey_hex).pluck(:id)

    user_ids.uniq.each do |user_id|
      Rails.cache.delete("dm_sibling_follows_user_#{user_id}")
      ReclassifyConversationsJob.perform_later(user_id)
    end
  end
end
