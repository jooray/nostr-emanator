# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../jobs/job_test_helper"

class MessageTest < ActiveSupport::TestCase
  include JobTestHelper

  def setup
    @account = build_account
    @conversation = build_conversation(@account)
  end

  # The whole reason bodies are stored at all is that decrypting costs two signer
  # round-trips. Storing them in the clear would be a much worse trade, so assert
  # against the raw column rather than trusting the attribute API.
  def test_message_content_is_ciphertext_at_rest
    message = build_message(content: "the actual secret text")

    raw = Message.connection.select_value("SELECT content FROM messages WHERE id = #{message.id}")

    refute_includes raw.to_s, "the actual secret text"
    assert_equal "the actual secret text", message.reload.content
  end

  def test_subject_file_metadata_and_tags_are_all_ciphertext_at_rest
    tags = [ [ "p", "a" * 64 ], [ "subject", "Project Nimbus" ] ]
    message = build_message(
      kind: Message::FILE_KIND,
      subject: "Project Nimbus",
      file_metadata: { "decryption-key" => "deadbeefkey" },
      raw_tags: tags
    )

    row = Message.connection.select_one(
      "SELECT subject, file_metadata, raw_tags FROM messages WHERE id = #{message.id}"
    )

    # file_metadata carries the AES key for the blob on the media server, and the
    # tags carry the participant list — both are secrets, not metadata.
    refute_includes row["subject"].to_s, "Project Nimbus"
    refute_includes row["file_metadata"].to_s, "deadbeefkey"
    refute_includes row["raw_tags"].to_s, "a" * 64

    message.reload
    assert_equal "Project Nimbus", message.subject
    assert_equal "deadbeefkey", message.file_metadata_hash["decryption-key"]
    assert_equal tags, message.tags
  end

  def test_missing_serialized_attributes_read_back_as_empty
    message = build_message

    assert_equal({}, message.reload.file_metadata_hash)
    assert_equal [], message.tags
  end

  # The self-addressed copy of an outbound message returns through our own inbound
  # subscription carrying the SAME rumor id. Without this index every sent message
  # would show up twice.
  def test_rumor_id_is_unique_per_account
    message = build_message

    assert_raises(ActiveRecord::RecordNotUnique) do
      Message.new(
        conversation: @conversation, account: @account, user: @account.user,
        rumor_id: message.rumor_id, sender_pubkey: @account.pubkey_hex,
        direction: "inbound", sort_at: Time.current, content: "duplicate"
      ).save!(validate: false)
    end
  end

  def test_the_same_rumor_can_exist_for_two_accounts
    other = build_account
    rumor_id = SecureRandom.hex(32)

    build_message(rumor_id: rumor_id)
    second = build_message(account: other, conversation: build_conversation(other), rumor_id: rumor_id)

    assert second.persisted?
  end

  # A hostile sender dating a rumor in 2030 would otherwise pin itself to the top
  # of the inbox forever.
  def test_sort_at_clamps_a_future_dated_rumor_to_when_we_saw_it
    seen_at = Time.current
    future = seen_at + 4.years

    assert_equal seen_at, Message.sort_at_for(future, seen_at)
  end

  def test_sort_at_keeps_an_honest_past_timestamp
    seen_at = Time.current
    earlier = seen_at - 3.hours

    assert_equal earlier, Message.sort_at_for(earlier, seen_at)
  end

  def test_sort_at_falls_back_to_seen_at_when_the_rumor_had_no_timestamp
    seen_at = Time.current

    assert_equal seen_at, Message.sort_at_for(nil, seen_at)
  end

  # Kind 4 puts the sender, recipient and timestamp in the clear on every relay.
  # It is only ever sent as an explicit downgrade for someone with no kind 10050,
  # and the model — not the composer — is what enforces that the user was asked.
  def test_a_legacy_kind_4_send_without_acknowledgement_is_rejected
    message = build_message_object(
      kind: Message::LEGACY_KIND, direction: "outbound", status: "pending",
      sender_pubkey: @account.pubkey_hex
    )

    refute message.valid?
    assert_match(/metadata is public/, message.errors[:base].join)
  end

  def test_an_acknowledged_legacy_send_is_allowed
    message = build_message(
      kind: Message::LEGACY_KIND, direction: "outbound", status: "pending",
      sender_pubkey: @account.pubkey_hex, legacy_downgrade_acked_at: Time.current
    )

    assert message.persisted?
    assert message.legacy_downgrade?, "the bubble needs a permanent legacy badge"
  end

  # Receiving legacy DMs needs no acknowledgement — the sender already leaked it.
  def test_a_legacy_kind_4_message_can_be_inbound_without_acknowledgement
    message = build_message(kind: Message::LEGACY_KIND)

    assert message.persisted?
    refute message.legacy_downgrade?
  end

  # A NIP-17 send must never be mistaken for a downgrade.
  def test_a_normal_outbound_message_is_not_a_legacy_downgrade
    message = build_message(direction: "outbound", status: "pending", legacy_downgrade_acked_at: nil)

    refute message.legacy_downgrade?
  end

  def test_the_downgrade_risks_are_stated_in_one_place
    assert Message::LEGACY_DOWNGRADE_RISKS.any?
    # The social-graph leak is the one users underestimate, so it must be named.
    assert_match(/can see that you messaged/, Message::LEGACY_DOWNGRADE_RISKS.join(" "))
  end

  def test_unsupported_kinds_are_rejected
    message = build_message_object(kind: 1)

    refute message.valid?
  end

  def test_transition_status_is_atomic
    message = build_message(direction: "outbound", status: "pending")

    assert message.transition_status(from: :pending, to: :sealing)
    assert_equal "sealing", message.status
    # The second caller lost the race and must not stomp the winner's state.
    refute message.transition_status(from: :pending, to: :sealing)
  end

  def test_stale_sending_finds_only_rows_stuck_mid_send
    fresh = build_message(direction: "outbound", status: "sealing")
    stuck = build_message(direction: "outbound", status: "publishing")
    stuck.update_column(:updated_at, (Message::STALE_SENDING_AFTER + 1.minute).ago)
    build_message(direction: "outbound", status: "sent")

    stale = Message.stale_sending.to_a
    assert_includes stale, stuck
    refute_includes stale, fresh
  end

  private

  def build_conversation(account)
    account.conversations.create!(
      user: account.user,
      participants_key: SecureRandom.hex(32),
      participant_pubkeys: [ account.pubkey_hex, SecureRandom.hex(32) ]
    )
  end

  def build_message(**attrs)
    build_message_object(**attrs).tap(&:save!)
  end

  def build_message_object(account: @account, conversation: @conversation, **attrs)
    Message.new({
      conversation: conversation, account: account, user: account.user,
      rumor_id: SecureRandom.hex(32), sender_pubkey: SecureRandom.hex(32),
      direction: "inbound", status: "received", sort_at: Time.current,
      content: "hello"
    }.merge(attrs))
  end
end
