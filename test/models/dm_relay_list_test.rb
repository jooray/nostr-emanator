# frozen_string_literal: true

require_relative "../test_helper"

class DmRelayListTest < ActiveSupport::TestCase
  def setup
    @pubkey = SecureRandom.hex(32)
  end

  def test_a_list_with_relays_is_deliverable
    list = DmRelayList.create!(pubkey_hex: @pubkey, relays: [ "wss://inbox.example" ], fetched_at: Time.current)

    assert list.deliverable?
  end

  # Per NIP-17, no 10050 means the person is not ready to receive DMs at all —
  # so the composer must refuse rather than guess at relays.
  def test_a_missing_list_is_not_deliverable
    list = DmRelayList.definitive_negative!(@pubkey)

    refute list.deliverable?
    assert list.missing?
  end

  # A 10050 that exists but lists zero relays is the same situation as no 10050.
  def test_a_list_with_no_relays_is_not_deliverable
    list = DmRelayList.create!(pubkey_hex: @pubkey, relays: [], fetched_at: Time.current)

    refute list.deliverable?
  end

  # Kind 10050 is replaceable. Treating a cache miss as "no list" would lead to
  # prompting the user to publish one that overwrites their other client's — the
  # single thing every participant in nostrability#169 agreed must not happen.
  # So `missing` has exactly one setter, named to make the requirement explicit.
  def test_definitive_negative_is_the_only_way_a_list_becomes_missing
    list = DmRelayList.definitive_negative!(@pubkey)

    assert list.missing?
    assert_equal [], list.relays
    assert list.checked_at.present?, "a negative has to record when it was established"
  end

  def test_definitive_negative_is_idempotent
    DmRelayList.definitive_negative!(@pubkey)
    DmRelayList.definitive_negative!(@pubkey)

    assert_equal 1, DmRelayList.where(pubkey_hex: @pubkey).count
  end

  def test_a_negative_can_be_replaced_by_a_real_list
    DmRelayList.definitive_negative!(@pubkey)
    list = DmRelayList.for_pubkey(@pubkey)
    list.update!(missing: false, relays: [ "wss://inbox.example" ], fetched_at: Time.current)

    assert list.reload.deliverable?
  end

  def test_lookup_is_case_insensitive
    DmRelayList.create!(pubkey_hex: @pubkey, relays: [], fetched_at: Time.current)

    assert_equal @pubkey, DmRelayList.for_pubkey(@pubkey.upcase)&.pubkey_hex
  end

  def test_a_never_fetched_list_is_stale
    assert DmRelayList.new(pubkey_hex: @pubkey).stale?
  end

  def test_a_freshly_fetched_list_is_not_stale
    refute DmRelayList.new(pubkey_hex: @pubkey, fetched_at: 1.minute.ago).stale?
  end

  # Re-probing someone who has no list at all can be much lazier than refreshing
  # someone who does — a missing list rarely appears, and probing costs a fan-out.
  def test_a_missing_list_is_rechecked_far_less_often_than_a_present_one
    age = DmRelayList::STALE_AFTER + 1.hour

    assert DmRelayList.new(pubkey_hex: @pubkey, fetched_at: age.ago).stale?
    refute DmRelayList.new(pubkey_hex: @pubkey, missing: true, fetched_at: age.ago).stale?
    assert DmRelayList.new(
      pubkey_hex: @pubkey, missing: true,
      fetched_at: (DmRelayList::RECHECK_MISSING_AFTER + 1.hour).ago
    ).stale?
  end

  def test_a_pubkey_has_at_most_one_row
    DmRelayList.create!(pubkey_hex: @pubkey, relays: [], fetched_at: Time.current)

    assert_raises(ActiveRecord::RecordNotUnique) do
      DmRelayList.new(pubkey_hex: @pubkey, relays: []).save!(validate: false)
    end
  end
end
