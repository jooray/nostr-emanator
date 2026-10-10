# frozen_string_literal: true

# Fills NostrProfile with the names of the people one account follows, so the
# composer's @mention lookup can search them. Fetches only profiles that are
# missing or older than NostrProfile::STALE_AFTER, in batches, capped per run;
# the next contact-list sync picks up where a capped run stopped.
class SyncFollowProfilesJob < ApplicationJob
  queue_as :default

  BATCH = 150
  MAX_PER_RUN = 1500

  def perform(pubkey_hex)
    follows = InteractionsCache.read_contact_list(pubkey_hex).to_a
    return if follows.empty?

    fresh = NostrProfile.fresh.where(pubkey_hex: follows).pluck(:pubkey_hex).to_set
    wanted = follows.reject { |pk| fresh.include?(pk) }.first(MAX_PER_RUN)
    return if wanted.empty?

    additional = Account.where(pubkey_hex: pubkey_hex).first&.write_relays || []
    fetcher = Nostr::ProfileFetcher.new(additional_relays: additional)
    wanted.each_slice(BATCH) do |slice|
      NostrProfile.store!(fetcher.fetch_batch(slice))
    end
  ensure
    InteractionsCache.release_inflight(:follow_profiles, "pubkey_#{pubkey_hex}") if pubkey_hex
  end
end
