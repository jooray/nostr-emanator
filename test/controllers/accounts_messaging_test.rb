# frozen_string_literal: true

require_relative "../test_helper"

# The re-pair prompt is the only thing standing between "messaging silently does
# not work for this account" and the user understanding why, so it is worth
# asserting it actually renders.
class AccountsMessagingTest < ActionDispatch::IntegrationTest
  include NostrTestHelper
  include SessionHelper

  def setup
    @user = create_signed_in_user
  end

  def test_settings_prompts_a_re_pair_for_an_account_paired_before_messaging_existed
    account = paired_account(dm_perms_version: nil)

    get settings_account_path(account)

    assert_response :success
    assert_match(/Messaging is not enabled/, response.body)
    assert_match(/Enable messaging/, response.body)
    assert_match(/reason=messaging/, response.body)
  end

  def test_settings_shows_messaging_enabled_for_a_freshly_paired_account
    account = paired_account(dm_perms_version: Nostr::AuthService::PERMISSIONS_VERSION)

    get settings_account_path(account)

    assert_response :success
    assert_match(/Messaging enabled/, response.body)
    refute_match(/Messaging is not enabled/, response.body)
  end

  # An account with no signer at all has a different problem; nagging about a
  # re-pair would be misleading.
  def test_settings_does_not_prompt_when_there_is_no_signer_at_all
    account = @user.accounts.create!(pubkey_hex: SecureRandom.hex(32), display_name: "Unpaired")

    get settings_account_path(account)

    assert_response :success
    refute_match(/Messaging is not enabled/, response.body)
  end

  def test_a_denied_signer_gets_different_copy
    account = paired_account(dm_perms_version: nil, settings: { "dm_capability" => "denied" })

    get settings_account_path(account)

    assert_match(/refused a message operation/, response.body)
  end

  # Both extra steps exist because they fail silently otherwise: without
  # "Always", every message prompts the phone; without the relay-auth whitelist,
  # Amber auto-rejects kind 22242 and the inbox just stays empty.
  # Both extra steps use Amber's own wording, checked against its strings.xml.
  # "Relay authentication" was invented and does not exist as a settings entry;
  # the real one is "Client auth whitelist", and it has no wildcard.
  def test_the_messaging_re_pair_page_explains_the_two_amber_traps
    account = paired_account(dm_perms_version: nil)

    get re_pair_account_path(account, reason: "messaging")

    assert_response :success
    assert_match(/Enable Messaging/, response.body)
    assert_match(/Always/, response.body)
    assert_match(/Client auth whitelist/, response.body)
    assert_match(/All relays/, response.body)
  end

  # The whitelist takes hostnames; the `*` belongs to the separate
  # "Authentication scope" prompt, so advising it here would send people looking
  # for a control that does not exist.
  def test_the_re_pair_page_does_not_advise_a_whitelist_wildcard
    account = paired_account(dm_perms_version: nil)

    get re_pair_account_path(account, reason: "messaging")

    refute_match(%r{whitelist[^<]*<code>\*</code>}, response.body)
  end

  def test_the_ordinary_re_pair_page_keeps_its_original_copy
    account = paired_account(dm_perms_version: Nostr::AuthService::PERMISSIONS_VERSION)

    get re_pair_account_path(account)

    assert_response :success
    assert_match(/Re-connect Signer/, response.body)
    refute_match(/relay authentication/i, response.body)
  end

  private

  def paired_account(**attrs)
    @user.accounts.create!({
      pubkey_hex: SecureRandom.hex(32),
      display_name: "Paired",
      signer_pubkey: SecureRandom.hex(32),
      app_privkey: SecureRandom.hex(32),
      app_pubkey: SecureRandom.hex(32)
    }.merge(attrs))
  end
end
