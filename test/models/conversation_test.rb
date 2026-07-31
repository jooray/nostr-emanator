# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../jobs/job_test_helper"

class ConversationTest < ActiveSupport::TestCase
  include JobTestHelper

  def setup
    @account = build_account
    @peer = SecureRandom.hex(32)
  end

  def test_subject_and_preview_are_ciphertext_at_rest
    conversation = build_conversation(subject: "Merger terms", last_message_preview: "wire the funds")

    row = Conversation.connection.select_one(
      "SELECT subject, last_message_preview FROM conversations WHERE id = #{conversation.id}"
    )

    refute_includes row["subject"].to_s, "Merger terms"
    refute_includes row["last_message_preview"].to_s, "wire the funds"
    assert_equal "Merger terms", conversation.reload.subject
  end

  # A room IS its participant set under NIP-17, so the same set must not be able
  # to produce two rooms for one account.
  def test_a_room_is_unique_per_account_and_protocol
    key = SecureRandom.hex(32)
    build_conversation(participants_key: key)

    assert_raises(ActiveRecord::RecordNotUnique) do
      build_conversation(participants_key: key)
    end
  end

  # Legacy kind-4 threads are deliberately separate rooms: different reply
  # targets, and the composer must refuse to send in them.
  def test_the_same_participants_can_have_both_a_nip17_and_a_legacy_room
    key = SecureRandom.hex(32)
    build_conversation(participants_key: key, protocol: "nip17")
    legacy = build_conversation(participants_key: key, protocol: "nip04")

    assert legacy.persisted?
    assert legacy.legacy?
  end

  def test_newest_subject_wins
    conversation = build_conversation
    conversation.apply_subject("first", 2.hours.ago)
    conversation.apply_subject("second", 1.hour.ago)

    assert_equal "second", conversation.reload.subject
  end

  # A message arriving late must not revert a title the room has moved past.
  def test_an_older_subject_does_not_overwrite_a_newer_one
    conversation = build_conversation
    conversation.apply_subject("current", 1.hour.ago)
    conversation.apply_subject("stale", 3.hours.ago)

    assert_equal "current", conversation.reload.subject
  end

  def test_a_blank_subject_is_ignored
    conversation = build_conversation
    conversation.apply_subject("keep me", 1.hour.ago)
    conversation.apply_subject("", Time.current)

    assert_equal "keep me", conversation.reload.subject
  end

  # An explicit decision by the user must survive automatic reclassification.
  def test_accept_locks_the_classification_against_reclassification
    conversation = build_conversation(classification: "request")
    conversation.accept!

    refute conversation.classify!("muted", "wot"), "a locked conversation must reject auto-reclassification"
    assert_equal "known", conversation.reload.classification
    assert_equal "manual", conversation.classification_reason
  end

  def test_block_also_locks
    conversation = build_conversation(classification: "known")
    conversation.block!

    refute conversation.classify!("known", "own_follow")
    assert_equal "muted", conversation.reload.classification
  end

  def test_an_unlocked_conversation_can_be_reclassified
    conversation = build_conversation(classification: "request")

    assert conversation.classify!("known", "sibling_follow")
    assert_equal "known", conversation.reload.classification
    assert_equal "sibling_follow", conversation.classification_reason
  end

  def test_peer_pubkeys_excludes_the_owning_account
    conversation = build_conversation(participant_pubkeys: [ @account.pubkey_hex, @peer ])

    assert_equal [ @peer ], conversation.peer_pubkeys
  end

  def test_group_is_more_than_two_participants
    refute build_conversation.group?
    assert build_conversation(
      participants_key: SecureRandom.hex(32),
      participant_pubkeys: [ @account.pubkey_hex, @peer, SecureRandom.hex(32) ]
    ).group?
  end

  def test_an_unknown_classification_is_rejected
    conversation = build_conversation
    conversation.classification = "whatever"

    refute conversation.valid?
  end

  private

  def build_conversation(**attrs)
    @account.conversations.create!({
      user: @account.user,
      participants_key: SecureRandom.hex(32),
      participant_pubkeys: [ @account.pubkey_hex, @peer ],
      peer_pubkey: @peer
    }.merge(attrs))
  end
end
