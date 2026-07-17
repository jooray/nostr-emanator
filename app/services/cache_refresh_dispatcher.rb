# frozen_string_literal: true

# Fires background refresh jobs when domain caches go stale.
# Always non-blocking. A 30 s in-flight guard keeps rapid page navigation from
# enqueueing duplicate jobs for the same user.
class CacheRefreshDispatcher
  class << self
    # Called from ApplicationController on every authenticated GET.
    def dispatch_if_stale(user)
      return unless user

      refresh_mute_lists(user) if InteractionsCache.muted_stale?(user)
      refresh_contacts_and_reactions(user)
      refresh_interactions(user) if InteractionsCache.events_stale?(user)
    end

    def refresh_interactions(user, stream_name: nil)
      return unless user
      return unless InteractionsCache.claim_inflight(:interactions, "user_#{user.id}")

      FetchInteractionsJob.perform_later(user.id, stream_name: stream_name)
    end

    def refresh_mute_lists(user)
      return unless user
      return unless InteractionsCache.claim_inflight(:mutes, "user_#{user.id}")

      SyncMuteListsJob.perform_later(user.id)
    end

    # Per-account: stale contact list / reactions trigger their own job each.
    # Missing caches are treated as stale.
    def refresh_contacts_and_reactions(user)
      user.accounts.each do |account|
        pubkey = account.pubkey_hex
        next if pubkey.blank?

        if InteractionsCache.contacts_stale?(pubkey) &&
           InteractionsCache.claim_inflight(:contacts, "pubkey_#{pubkey}")
          SyncContactListsJob.perform_later(pubkey)
        end

        if InteractionsCache.reactions_stale?(pubkey) &&
           InteractionsCache.claim_inflight(:reactions, "pubkey_#{pubkey}")
          SyncReactionsJob.perform_later(pubkey)
        end
      end
    end

    def refresh_profiles(pubkeys)
      pubkeys = Array(pubkeys).compact.uniq
      return if pubkeys.empty?
      return unless InteractionsCache.claim_inflight(:profiles, Digest::MD5.hexdigest(pubkeys.sort.join))

      RefreshProfilesJob.perform_later(pubkeys)
    end
  end
end
