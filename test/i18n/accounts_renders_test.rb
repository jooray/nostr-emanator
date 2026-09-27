# frozen_string_literal: true

require_relative "../test_helper"

# Renders every accounts page once so a mistyped translation key fails here
# (raise_on_missing_translations is on in test) rather than in production.
class AccountsRendersTest < ActionDispatch::IntegrationTest
  include NostrTestHelper
  include SessionHelper

  def setup
    @user = create_nostr_user
    sign_in_without_landing(@user)
  end

  # SessionHelper#sign_in_as follows the redirect to the dashboard, which is a
  # different area's page; stay out of it so only accounts pages are exercised.
  def sign_in_without_landing(user)
    pubkey, privkey = keypair
    user.update!(pubkey_hex: pubkey, npub: Nostr::KeyConverter.hex_to_npub(pubkey))
    get nostr_login_path
    challenge = response.body.match(/data-nostr-login-challenge="([0-9a-f]+)"/)[1]
    event = signed_event(privkey: privkey, pubkey: pubkey, kind: 22_242, content: "Sign in to Emanator",
                         tags: [ [ "challenge", challenge ], [ "domain", login_domain ] ])
    post auth_nostr_callback_path, params: { pubkey: pubkey, signed_event: event.to_json }
  end

  def paired_account(**attrs)
    @user.accounts.create!({
      pubkey_hex: SecureRandom.hex(32),
      display_name: "Paired",
      signer_pubkey: SecureRandom.hex(32),
      app_privkey: SecureRandom.hex(32),
      app_pubkey: SecureRandom.hex(32),
      write_relays: [ "wss://relay.example.com" ]
    }.merge(attrs))
  end

  # Swap a class's constructor for a stub, keeping the tests off the network.
  def stub_new(klass, fake)
    original = klass.method(:new)
    klass.define_singleton_method(:new) { |*, **| fake }
    yield
  ensure
    klass.define_singleton_method(:new, original)
  end

  def test_empty_index
    @user.accounts.destroy_all # login imports the user's own identity
    get accounts_path
    assert_response :success
    assert_match "No accounts paired", response.body
  end

  def test_index_show_settings_edit
    account = paired_account
    get accounts_path
    assert_response :success
    assert_match "0 posts", response.body
    assert_match "Signer connected", response.body

    get account_path(account)
    assert_response :success
    assert_match "No scheduled posts.", response.body
    assert_match "Create one", response.body

    get settings_account_path(account)
    assert_response :success
    assert_match "Danger Zone", response.body
    assert_match "Messaging needs re-pair", response.body
    assert_match "Messaging is not enabled for Paired", response.body

    get edit_account_path(account)
    assert_response :success
    assert_match "Writing Personality", response.body
    assert_match "Leave blank to use the default", response.body
    assert_select "code.font-mono", Account.default_blossom_server
  end

  def test_invalid_update_renders_the_error_heading
    account = paired_account
    patch account_path(account), params: { account: { personality: "x" * (Account::MAX_PERSONALITY_LENGTH + 1) } }
    assert_response :unprocessable_entity
    assert_match "1 error prevented this account from being saved:", response.body
  end

  def test_pairing_pages
    get new_account_path
    assert_response :success
    assert_match "Connect via NIP-46", response.body
    assert_select "a[href=?]", "https://github.com/greenart7c3/Amber", text: "Amber"

    account = paired_account
    get re_pair_account_path(account)
    assert_response :success
    assert_match "Re-connect Signer", response.body
  end

  def test_recent_frames
    account = paired_account
    events_fetcher = Object.new
    events_fetcher.define_singleton_method(:fetch) { |*, **| [] }
    stub_new(Nostr::EventFetcher, events_fetcher) do
      get recent_events_account_path(account)
    end
    assert_response :success
    assert_match "No recent events found on relays.", response.body

    interactions = [ {
      interaction_type: :reply, author_pubkey: SecureRandom.hex(32), author_name: "Alice",
      content: "hi", created_at: 2.hours.ago.to_i, event_id: SecureRandom.hex(32),
      original_post_content: "orig", original_post_event_id: SecureRandom.hex(32),
      target_account: account, referenced_event_ids: []
    } ]
    fetcher = Object.new
    fetcher.define_singleton_method(:fetch_for_account) { |*, **| interactions }
    fetcher.define_singleton_method(:enrich_with_profiles) { |*| }
    fetcher.define_singleton_method(:enrich_with_original_posts) { |*| }
    stub_new(Nostr::InteractionsFetcher, fetcher) do
      get recent_interactions_account_path(account)
    end
    assert_response :success
    assert_match "about 2 hours ago", response.body
    assert_match ">Your post</a>:", response.body
    assert_match "Sign &amp; Publish", response.body
  end

  def test_profile_editor
    account = paired_account(display_name: "", username: "")
    fetcher = Object.new
    fetcher.define_singleton_method(:fetch_raw_event) { |_pubkey| nil }
    stub_new(Nostr::ProfileFetcher, fetcher) do
      get profile_account_path(account)
    end
    assert_response :success
    assert_match "&larr; Back to account", response.body
    assert_match "kind&nbsp;0", response.body
    assert_match "Re-pair this account", response.body
    assert_match "Publish profile", response.body
  end

  def test_messaging_repair_list_for_several_accounts
    accounts = [ paired_account, paired_account ]
    html = ApplicationController.render(partial: "accounts/messaging_repair_list", locals: { accounts: accounts })
    assert_match "2 accounts cannot message yet", html
  end

  def test_pages_render_in_slovak_without_missing_keys
    @user.update!(locale: "sk")
    account = paired_account
    [ accounts_path, account_path(account), settings_account_path(account), edit_account_path(account),
      new_account_path, re_pair_account_path(account, reason: "messaging") ].each do |path|
      get path
      assert_response :success, path
    end
  end
end
