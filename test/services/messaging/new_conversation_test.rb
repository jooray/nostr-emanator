# frozen_string_literal: true

require_relative "../../test_helper"

class NewConversationTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper
  include ApiTestHelper

  def setup
    @user = create_api_user
    @account = create_signed_account(@user)
    @peer = SecureRandom.hex(32)
  end

  def test_starts_a_known_room_and_queues_the_message
    result = nil
    assert_enqueued_with(job: SendDirectMessageJob) do
      result = start(recipient: Nostr::KeyConverter.hex_to_npub(@peer))
    end

    assert result.ok?, result.error
    room = result.conversation
    assert room.nip17?
    assert_equal @peer, room.peer_pubkey
    assert_equal [ @account.pubkey_hex, @peer ].sort, room.participant_pubkeys
    assert_equal Nostr::Nip17.participants_key([ @account.pubkey_hex, @peer ]), room.participants_key
    assert room.known?, "writing to someone is the Known rule"
    assert_equal [ @peer ], result.message.rumor["tags"].select { |t| t[0] == "p" }.map { |t| t[1] }
  end

  # The room is the participant set: a second "new message" to the same person
  # continues the thread instead of opening another.
  def test_continues_an_existing_room
    first = start(recipient: @peer).conversation
    second = start(recipient: "nostr:#{Nostr::KeyConverter.hex_to_npub(@peer)}", content: "again").conversation

    assert_equal first, second
    assert_equal 2, first.messages.count
  end

  def test_a_stranger_who_wrote_first_moves_to_known
    participants = [ @account.pubkey_hex, @peer ].sort
    room = @user.conversations.create!(
      account: @account, participant_pubkeys: participants, participants_key: Nostr::Nip17.participants_key(participants),
      peer_pubkey: @peer, classification: "request", classification_reason: "unclassified", last_message_at: 1.day.ago
    )

    assert_equal room, start(recipient: @peer).conversation
    assert room.reload.known?
  end

  def test_refuses_without_a_message_and_leaves_no_empty_room
    result = start(content: "  ")

    refute result.ok?
    assert_equal 0, @user.conversations.count
  end

  def test_refuses_a_bad_recipient
    refute start(recipient: "npub1notreally").ok?
    refute start(recipient: "").ok?
  end

  def test_refuses_an_account_that_cannot_message_or_is_not_ours
    old = create_signed_account(@user, dm_perms_version: nil)
    refute start(account_id: old.id).ok?

    stranger = create_signed_account(create_api_user)
    refute start(account_id: stranger.id).ok?
    assert_equal 0, Conversation.count
  end

  private

  def start(account_id: @account.id, recipient: @peer, content: "hi there")
    Messaging::NewConversation.call(@user, account_id: account_id, recipient: recipient, content: content)
  end
end
