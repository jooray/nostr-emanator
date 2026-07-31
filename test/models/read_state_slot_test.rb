# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../jobs/job_test_helper"

# NIP-RS is a grow-only max register. Nearly every test here is about that one
# property, because it is what makes two devices publishing concurrently safe
# without any coordination.
class ReadStateSlotTest < ActiveSupport::TestCase
  include JobTestHelper

  def setup
    @account = build_account
    # Real Unix timestamps inside the fetch horizon. Anything older is pruned on
    # merge (see the horizon test below), so toy values like 100/200 would vanish.
    @now = Time.current.to_i
    @earlier = @now - 3600
  end

  def test_contexts_are_ciphertext_at_rest
    peer = "b" * 64
    slot = build_slot(contexts: { peer => 1_700_000_000 })

    raw = ReadStateSlot.connection.select_value("SELECT contexts FROM read_state_slots WHERE id = #{slot.id}")

    # Context ids are peer pubkeys — i.e. who this account talks to.
    refute_includes raw.to_s, peer
    assert_equal 1_700_000_000, slot.reload.context_map[peer]
  end

  def test_merging_advances_a_context
    slot = build_slot(contexts: { "a" => @earlier })

    assert slot.merge_contexts!({ "a" => @now })
    assert_equal @now, slot.reload.context_map["a"]
  end

  # The merge rule is max(): a device that is behind must never rewind one that
  # is ahead, or read state would flap between devices forever.
  def test_merging_never_lowers_a_context
    slot = build_slot(contexts: { "a" => @now })

    refute slot.merge_contexts!({ "a" => @earlier })
    assert_equal @now, slot.reload.context_map["a"]
  end

  def test_merging_reports_no_change_when_nothing_moved
    slot = build_slot(contexts: { "a" => @now })

    refute slot.merge_contexts!({ "a" => @now })
  end

  def test_merging_adds_unseen_contexts
    slot = build_slot(contexts: { "a" => @now })

    assert slot.merge_contexts!({ "b" => @earlier })
    assert_equal({ "a" => @now, "b" => @earlier }, slot.reload.context_map)
  end

  def test_timestamps_outside_the_spec_range_are_dropped
    slot = build_slot(contexts: {})

    refute slot.merge_contexts!({ "a" => -1, "b" => ReadStateSlot::MAX_TIMESTAMP + 1 })
    assert_equal({}, slot.reload.context_map)
  end

  # Keeps published events well under the spec's 64 KB ceiling.
  def test_contexts_older_than_the_horizon_are_pruned_on_merge
    stale = (ReadStateSlot::HORIZON + 2.days).ago.to_i
    slot = build_slot(contexts: {})
    slot.merge_contexts!({ "old" => stale, "fresh" => Time.current.to_i })

    assert_equal [ "fresh" ], slot.reload.context_map.keys
  end

  def test_a_new_slot_id_is_32_hex_characters
    assert_match(/\A[0-9a-f]{32}\z/, ReadStateSlot.generate_slot_id)
  end

  def test_slot_ids_are_unique_per_slot
    assert_equal 20, Array.new(20) { ReadStateSlot.generate_slot_id }.uniq.size
  end

  def test_the_d_tag_carries_the_slot_id
    slot = build_slot
    assert_equal "read-state:#{slot.slot_id}", slot.d_tag
  end

  def test_a_slot_id_is_unique_per_account
    slot = build_slot

    assert_raises(ActiveRecord::RecordNotUnique) { build_slot(slot_id: slot.slot_id) }
  end

  def test_marking_dirty_defers_publishing_by_the_debounce
    slot = build_slot
    now = Time.current
    slot.mark_dirty!(now: now)

    assert slot.dirty?
    assert_in_delta (now + ReadStateSlot::DEBOUNCE).to_i, slot.publish_after.to_i, 1
  end

  def test_due_for_publish_only_finds_our_own_dirty_slots_past_their_debounce
    due = build_slot(own: true, dirty: true, publish_after: 1.minute.ago)
    build_slot(own: true, dirty: true, publish_after: 1.minute.from_now)   # still debouncing
    build_slot(own: true, dirty: false, publish_after: 1.minute.ago)       # nothing to say
    build_slot(own: false, dirty: true, publish_after: 1.minute.ago)       # another device's slot

    assert_equal [ due ], ReadStateSlot.due_for_publish.to_a
  end

  def test_contexts_default_to_empty_rather_than_nil
    assert_equal({}, build_slot.context_map)
  end

  private

  def build_slot(**attrs)
    @account.read_state_slots.create!({ slot_id: ReadStateSlot.generate_slot_id }.merge(attrs))
  end
end
