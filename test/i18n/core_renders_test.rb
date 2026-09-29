# frozen_string_literal: true

require_relative "../test_helper"

# Renders the core surfaces (login, layout and rail, settings, API tokens, the
# shared forme row and console helpers) once so a mistyped translation key fails
# here (raise_on_missing_translations is on in test) rather than in production.
class CoreRendersTest < ActionDispatch::IntegrationTest
  include NostrTestHelper
  include SessionHelper

  def test_login_page_renders_with_the_language_switcher
    get nostr_login_path

    assert_response :success
    assert_match "Sign in with your Nostr identity", response.body
    assert_match "Open in your signer app", response.body
    assert_match "Only scan a QR code shown on <strong>your own screen</strong>", response.body
    assert_match %r{<a [^>]*href="https://getalby.com"}, response.body
    assert_match "Slovenčina", response.body
  end

  def test_settings_renders_rail_and_api_tokens
    user = create_nostr_user
    sign_in_without_landing(user)
    ApiToken.generate(user, name: "agent")
    account = paired_account(user)
    account.posts.create!(content: "x", status: "failed", scheduled_at: 1.hour.ago)

    get edit_user_path

    assert_response :success
    assert_match "Settings", response.body
    assert_match "Station status", response.body
    # Both the desktop rail and the mobile panel link to Settings, after Messages.
    assert_select "a[href=?]", edit_user_path, count: 2
    assert_match(/Messages.*Settings/m, css_select("nav ul").first.text)
    assert_match "2 identities", response.body
    assert_match "1 never went out", response.body
    assert_match "API Tokens (MCP)", response.body
    assert_match "Revoke this token?", response.body
    assert_match "Skip to content", response.body
  end

  def test_settings_flashes
    user = create_nostr_user
    sign_in_without_landing(user)

    patch user_path, params: { user: { event_viewer: "njump" } }
    assert_equal "Event viewer updated.", flash[:notice]

    post api_tokens_path, params: { name: "" }
    assert_equal "Token name required.", flash[:alert]
  end

  def test_forme_row_and_console_helpers
    user = create_nostr_user
    account = paired_account(user)
    post = account.posts.create!(content: "hello", status: "failed", scheduled_at: 1.hour.ago)

    html = ApplicationController.render(partial: "shared/forme_row", locals: { post: post, failed: true })
    assert_match "Never reached a relay. Nothing was published.", html
    assert_match "Retry", html

    helpers = ApplicationController.helpers
    assert_equal "Waiting for approval in signer", helpers.status_label("awaiting_signature")
    assert_equal "Draft", helpers.status_label("draft")
    assert_equal "Not published yet.", helpers.delivery_sentence(post)
  end

  private

  def sign_in_without_landing(user)
    pubkey, privkey = keypair
    user.update!(pubkey_hex: pubkey, npub: Nostr::KeyConverter.hex_to_npub(pubkey))
    get nostr_login_path
    challenge = response.body.match(/data-nostr-login-challenge="([0-9a-f]+)"/)[1]
    event = signed_event(privkey: privkey, pubkey: pubkey, kind: 22_242, content: "Sign in to Emanator",
                         tags: [ [ "challenge", challenge ], [ "domain", login_domain ] ])
    post auth_nostr_callback_path, params: { pubkey: pubkey, signed_event: event.to_json }
  end

  def paired_account(user)
    user.accounts.create!(
      pubkey_hex: SecureRandom.hex(32),
      display_name: "Paired",
      signer_pubkey: SecureRandom.hex(32),
      app_privkey: SecureRandom.hex(32),
      app_pubkey: SecureRandom.hex(32)
    )
  end
end
