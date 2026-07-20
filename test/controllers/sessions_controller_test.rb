# frozen_string_literal: true

require_relative "../test_helper"

class SessionsControllerTest < ActionDispatch::IntegrationTest
  include NostrTestHelper

  def test_nip07_authentication_rotates_session_and_isolates_pending_nip46
    pubkey, privkey = keypair
    create_user(pubkey)

    get nostr_login_path
    assert_response :success

    challenge = response.body.match(/data-nostr-login-challenge="([0-9a-f]+)"/)[1]
    pending = NostrAuthSession.find_by!(session_id: response_session_id)
    old_cookie = cookies.to_hash
    event = signed_event(
      privkey: privkey,
      pubkey: pubkey,
      kind: 22_242,
      content: "Sign in to Emanator",
      tags: [["challenge", challenge], ["domain", "emanator.cypherpunk.today"]]
    )

    post auth_nostr_callback_path, params: { pubkey: pubkey, signed_event: event.to_json }

    assert_redirected_to dashboard_path
    assert pending.reload.consumed_at?
    assert_equal "consumed", pending.temp_privkey

    attacker = open_session
    old_cookie.each { |name, value| attacker.cookies[name] = value }
    attacker.post auth_nostr_poll_path
    refute attacker.response.parsed_body["authenticated"]
    assert_nil attacker.response.parsed_body["redirect_url"]
  end

  def test_logout_consumes_pending_account_pairing_session
    user = create_user
    post_login_session(user)

    get new_account_path
    pending = NostrAuthSession.order(:created_at).last
    assert_nil pending.consumed_at

    delete logout_path

    assert_redirected_to nostr_login_path
    assert pending.reload.consumed_at?
    get accounts_path
    assert_redirected_to nostr_login_path
  end

  private

  def response_session_id
    NostrAuthSession.order(:created_at).last.session_id
  end

  def create_user(pubkey = nil)
    pubkey ||= keypair.first
    User.create!(pubkey_hex: pubkey, npub: Nostr::KeyConverter.hex_to_npub(pubkey), display_name: "Tester")
  end

  def post_login_session(user)
    pubkey, privkey = keypair
    user.update!(pubkey_hex: pubkey, npub: Nostr::KeyConverter.hex_to_npub(pubkey))
    get nostr_login_path
    challenge = response.body.match(/data-nostr-login-challenge="([0-9a-f]+)"/)[1]
    event = signed_event(
      privkey: privkey,
      pubkey: pubkey,
      kind: 22_242,
      content: "Sign in to Emanator",
      tags: [["challenge", challenge], ["domain", "emanator.cypherpunk.today"]]
    )
    post auth_nostr_callback_path, params: { pubkey: pubkey, signed_event: event.to_json }
    follow_redirect!
  end
end
