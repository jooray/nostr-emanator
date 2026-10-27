# frozen_string_literal: true

require_relative "../../test_helper"

class MessagingApiTest < ActionDispatch::IntegrationTest
  include ApiTestHelper

  def setup
    @user = create_api_user
    @account = create_signed_account(@user)
    peer = SecureRandom.hex(32)
    participants = [ @account.pubkey_hex, peer ].sort
    @conversation = @user.conversations.create!(
      account: @account, participant_pubkeys: participants, participants_key: Digest::SHA256.hexdigest(participants.join(",")),
      peer_pubkey: peer, classification: "known", unread_count: 2, last_message_at: Time.current
    )
    @conversation.messages.create!(
      account: @account, user: @user, direction: "in", kind: 14, content: "hello", status: "received",
      rumor_id: SecureRandom.hex(32), sender_pubkey: peer, sort_at: Time.current, rumor_created_at: Time.current
    )
  end

  def test_inbox_and_thread
    api_get "/api/v1/conversations"
    assert_response :success
    assert_equal 1, json.dig("counts", "known")
    assert_equal 2, json["conversations"].first["unread_count"]

    api_get "/api/v1/conversations/#{@conversation.id}"
    assert_response :success
    assert_equal [ "hello" ], json["messages"].map { |m| m["content"] }
    # The Android client keys bubbles off the enum key, not the stored "in"/"out".
    assert_equal [ "inbound" ], json["messages"].map { |m| m["direction"] }
    assert_includes %w[nip17 checking best_effort], json["delivery"]
    assert_equal 0, @conversation.reload.unread_count, "opening a thread marks it read"
  end

  def test_requests_tab_and_accept
    @conversation.update!(classification: "request")
    api_get "/api/v1/conversations", params: { tab: "requests" }
    assert_equal 1, json["conversations"].size

    api_post "/api/v1/conversations/#{@conversation.id}/accept"
    assert_equal "known", @conversation.reload.classification
    assert @conversation.classification_locked
  end

  def test_someone_elses_thread_is_not_found
    other = create_api_user
    @device_token = ApiToken.issue_device!(other, name: "x")

    api_get "/api/v1/conversations/#{@conversation.id}"
    assert_response :not_found
  end

  def test_start_a_conversation_from_a_chosen_account
    other = create_signed_account(@user, display_name: "Other")
    peer = SecureRandom.hex(32)

    api_post "/api/v1/conversations", params: { account_id: other.id, recipient: Nostr::KeyConverter.hex_to_npub(peer), content: "first" }

    assert_response :created
    assert_equal other.id, json.dig("conversation", "account", "id") || Conversation.find(json.dig("conversation", "id")).account_id
    assert_equal "first", json.dig("message", "content")
  end

  def test_starting_a_conversation_without_recipient_is_an_error
    api_post "/api/v1/conversations", params: { account_id: @account.id, recipient: "nope", content: "first" }

    assert_response :unprocessable_entity
    assert json["error"].present?
  end
end
