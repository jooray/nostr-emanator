# frozen_string_literal: true

# Inbound DM sync progress for one account: the backfill cursor, decrypt counts
# for the progress UI, and enough state to tell a live pipeline from a dead one.
#
# Real columns rather than a JSON blob in `account.settings` because concurrent
# jobs advance the cursor and would race a blob.
class DmSyncState < ApplicationRecord
  belongs_to :account

  # Bounds on how far back a first sync will go. Decryption is the expensive
  # resource here (two signer round-trips per wrap), so the backfill is capped on
  # both count and age — whichever is hit first.
  MAX_BACKFILL_WRAPS = 2_000
  MAX_BACKFILL_AGE = 180.days

  # Wrapper timestamps are randomised up to two days into the past, so `since`
  # can only ever be a coarse hint; wrap_id uniqueness is what makes dedupe
  # correct. Overlap generously rather than risk missing a wrap.
  SINCE_SLACK = 2.days + 1.hour

  enum :status, {
    idle: "idle",
    backfilling: "backfilling",
    decrypting: "decrypting",
    error: "error"
  }, validate: true

  def self.for_account(account)
    find_or_create_by!(account_id: account.id)
  end

  # Where to resume a subscription or poll from.
  def since
    return MAX_BACKFILL_AGE.ago.to_i if last_wrap_seen_at.nil?

    (last_wrap_seen_at - SINCE_SLACK).to_i
  end

  def backfill_complete? = backfill_completed_at.present?

  def progress!(step:, pending: nil, processed: nil)
    attrs = { step: step, last_synced_at: Time.current }
    attrs[:pending_wraps] = pending if pending
    attrs[:processed_wraps] = processed if processed
    update!(attrs)
  end

  def fail!(message)
    update!(status: "error", last_error: message.to_s.truncate(240), step: nil)
  end

  def finish!
    update!(status: "idle", step: nil, last_error: nil, last_synced_at: Time.current)
  end

  # Has the poll's relay set changed since the watermark was last trusted?
  #
  # A `since` cursor is only meaningful for relays we were already listening to.
  # Adding one — a newly published kind 10050, a new discovery relay — makes the
  # cursor wrong for that relay specifically, and there is no per-relay cursor to
  # fix it with. Order is irrelevant, so the digest is over the sorted set.
  def relays_unchanged?(relays)
    relays_digest.present? && relays_digest == self.class.digest_for(relays)
  end

  def observe_relays!(relays)
    digest = self.class.digest_for(relays)
    return if relays_digest == digest

    update!(relays_digest: digest)
  end

  def self.digest_for(relays)
    Digest::SHA1.hexdigest(Array(relays).map(&:to_s).sort.join("\n"))
  end

  # Advance the "newest wrap we have seen" watermark. Monotonic: an older wrap
  # arriving late must not rewind the cursor.
  def observe_wrap!(seen_at)
    return if seen_at.blank?
    return if last_wrap_seen_at.present? && last_wrap_seen_at >= seen_at

    update!(last_wrap_seen_at: seen_at)
  end
end
