# frozen_string_literal: true

require_relative "../test_helper"

# Renders every messaging and interactions surface once, so a mistyped
# translation key fails here (raise_on_missing_translations) instead of in
# front of a user.
class MessagingRendersTest < ActionDispatch::IntegrationTest
  include NostrTestHelper
  include SessionHelper
  include CacheHelper

  def setup
    @user = create_signed_in_user
    @account = @user.accounts.create!(
      pubkey_hex: SecureRandom.hex(32), display_name: "Main", npub: "npub_main",
      signer_pubkey: SecureRandom.hex(32), app_privkey: SecureRandom.hex(32),
      app_pubkey: SecureRandom.hex(32),
      dm_perms_version: Nostr::AuthService::PERMISSIONS_VERSION,
      settings: { "amber_auth_blocked_at" => Time.current.iso8601, "amber_auth_blocked_relay" => "auth.nostr1.com" }
    )
    @peers = [ SecureRandom.hex(32), SecureRandom.hex(32) ]
  end

  def test_inbox_and_requests_render
    room(classification: "known", participants: [ @peers.first ])
    room(classification: "request", participants: @peers, protocol: "nip04")

    get messages_path
    assert_response :success
    assert_includes response.body, "1 account not relay-authenticated"
    assert_includes response.body, "<code>auth.nostr1.com</code>"

    get messages_path(tab: "requests")
    assert_response :success
    assert_includes response.body, "3 people"

    get messages_path(tab: "requests", unread: "1")
    assert_response :success
    assert_includes response.body, "No message requests."
  end

  def test_a_thread_with_every_kind_of_bubble_renders
    conversation = room(classification: "request", participants: @peers)
    add_message(conversation, direction: "inbound", sender_pubkey: @peers.first, status: "received", kind: Message::FILE_KIND,
                              file_metadata: { "file-type" => "image/png" })
    add_message(conversation, status: "sent", delivery_tier: "nip65")
    add_message(conversation, status: "failed", error: "No relay accepted the message.")
    add_message(conversation, status: "sealing", step: nil)

    get conversation_path(conversation)
    assert_response :success
    assert_includes response.body, "[encrypted file — image/png]"
    assert_includes response.body, "Best effort"
    assert_includes response.body, "Not sent"
    assert_includes response.body, "Sending…"
    assert_includes response.body, "and 1 more"

    post accept_conversation_path(conversation)
    assert_equal "Moved to your inbox.", flash[:notice]

    post mark_all_read_messages_path
    assert_equal "Nothing unread.", flash[:notice]
  end

  def test_interactions_page_and_card_render
    get interactions_path
    assert_response :success

    html = @user.with_locale do
      ApplicationController.render(
        partial: "interactions/interactions_content",
        locals: { interactions: [ {
          event_id: SecureRandom.hex(32), author_pubkey: @peers.first, author_name: "Alice",
          interaction_type: :quote, target_account: @account, created_at: 1.hour.ago.to_i,
          content: "hello", original_post_content: "original", original_post_author: "Bob",
          original_post_author_pubkey: @peers.last, original_post_event_id: SecureRandom.hex(32)
        } ] }
      )
    end
    assert_includes html, "Quoted post (Bob)"
    assert_includes html, "Mute @Alice"
    assert_includes html, "about 1 hour ago"

    empty = ApplicationController.render(partial: "interactions/interactions_content", locals: { interactions: [] })
    assert_includes empty, "No interactions yet"
  end

  private

  def room(classification:, participants:, protocol: "nip17")
    @account.conversations.create!(
      user: @user, participants_key: SecureRandom.hex(32),
      participant_pubkeys: [ @account.pubkey_hex, *participants ], peer_pubkey: participants.first,
      classification: classification, protocol: protocol, last_message_at: Time.current,
      last_message_preview: "hi", unread_count: 0
    )
  end

  def add_message(conversation, direction: "outbound", sender_pubkey: @account.pubkey_hex, kind: Message::CHAT_KIND, **attrs)
    conversation.messages.create!({
      account: @account, user: @user, sender_pubkey: sender_pubkey, direction: direction,
      kind: kind, content: "body", rumor_id: SecureRandom.hex(32), rumor_created_at: Time.current,
      sort_at: Time.current
    }.merge(attrs))
  end
end
