# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../jobs/job_test_helper"

class GiftWrapTest < ActiveSupport::TestCase
  include JobTestHelper

  def setup
    @account = build_account
  end

  # This uniqueness is the entire point of the table: the same wrap arrives from
  # every inbox relay, and each decrypt costs two signer round-trips.
  def test_a_wrap_is_recorded_once_per_account
    wrap_id = SecureRandom.hex(32)
    build_wrap(wrap_id: wrap_id)

    assert_raises(ActiveRecord::RecordNotUnique) { build_wrap(wrap_id: wrap_id) }
  end

  def test_two_accounts_can_each_receive_the_same_wrap
    wrap_id = SecureRandom.hex(32)
    build_wrap(wrap_id: wrap_id)
    other = build_account

    assert other.gift_wraps.create!(
      wrap_id: wrap_id, seen_at: Time.current, wrap_created_at: Time.current
    ).persisted?
  end

  # Two workers must never both spend signer calls on one wrap.
  def test_only_one_caller_can_claim_a_wrap
    wrap = build_wrap

    assert wrap.claim!
    assert_equal "decrypting", wrap.status
    refute wrap.claim!
  end

  def test_decoding_links_the_message_and_drops_the_cached_event
    wrap = build_wrap(wrap_event: { "id" => "x", "content" => "ciphertext" })
    wrap.claim!
    message = build_dm(@account)

    wrap.decode!(message)

    assert_equal "decoded", wrap.status
    assert_equal message.id, wrap.message_id
    # Only kept so a retry after the signer was offline needed no refetch.
    assert_nil wrap.reload.wrap_event
  end

  # Malformed or hostile input will not become valid, so it must never be retried.
  def test_rejecting_is_terminal_and_records_the_reason
    wrap = build_wrap
    wrap.reject!(:seal_pubkey_mismatch)

    assert_equal "rejected", wrap.status
    assert_equal "seal_pubkey_mismatch", wrap.last_error
    assert wrap.resolved?
    refute_includes GiftWrap.queue, wrap
  end

  def test_a_retryable_failure_stays_queued
    wrap = build_wrap
    wrap.defer!("signer timeout")

    assert_equal "pending", wrap.status
    assert_equal 1, wrap.attempts
    assert_includes GiftWrap.queue, wrap
  end

  # Otherwise a permanently unreachable signer would be retried forever, each
  # attempt costing the user's phone battery.
  def test_a_wrap_gives_up_after_max_attempts
    wrap = build_wrap

    GiftWrap::MAX_ATTEMPTS.times { wrap.defer!("signer offline") }

    assert_equal "undecryptable", wrap.status
    assert_equal GiftWrap::MAX_ATTEMPTS, wrap.attempts
    assert wrap.resolved?
  end

  def test_the_queue_is_newest_first_so_the_inbox_is_useful_immediately
    old = build_wrap(wrap_created_at: 3.days.ago)
    new = build_wrap(wrap_created_at: 1.hour.ago)

    assert_equal [ new, old ], GiftWrap.queue.to_a
  end

  def test_stuck_finds_only_rows_abandoned_mid_decrypt
    claimed = build_wrap
    claimed.claim!
    abandoned = build_wrap
    abandoned.claim!
    abandoned.update_column(:updated_at, (GiftWrap::STUCK_AFTER + 1.minute).ago)

    stuck = GiftWrap.stuck.to_a
    assert_includes stuck, abandoned
    refute_includes stuck, claimed
  end

  private

  def build_wrap(**attrs)
    @account.gift_wraps.create!({
      wrap_id: SecureRandom.hex(32),
      wrap_created_at: Time.current,
      seen_at: Time.current,
      relays: [ "wss://relay.example" ]
    }.merge(attrs))
  end

  def build_dm(account)
    conversation = account.conversations.create!(
      user: account.user,
      participants_key: SecureRandom.hex(32),
      participant_pubkeys: [ account.pubkey_hex ]
    )
    conversation.messages.create!(
      account: account, user: account.user,
      rumor_id: SecureRandom.hex(32), sender_pubkey: SecureRandom.hex(32),
      direction: "inbound", status: "received", sort_at: Time.current, content: "hi"
    )
  end
end
