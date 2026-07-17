# frozen_string_literal: true

# Re-fetches kind 0 profiles for a list of pubkeys and caches the latest
# version. Fired when a cached profile is older than PROFILE_STALE_AFTER so
# renamed/re-pictured accounts eventually update without manual action.
class RefreshProfilesJob < ApplicationJob
  queue_as :default

  def perform(pubkeys)
    pubkeys = Array(pubkeys).compact.uniq
    return if pubkeys.empty?

    fetcher = Nostr::ProfileFetcher.new
    profiles = fetcher.fetch_batch(pubkeys)

    pubkeys.each do |pubkey|
      InteractionsCache.write_profile(pubkey, profiles[pubkey] || {})
    end
  ensure
    InteractionsCache.release_inflight(:profiles, Digest::MD5.hexdigest(pubkeys.sort.join))
  end
end
