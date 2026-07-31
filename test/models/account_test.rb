# frozen_string_literal: true

require "test_helper"

class AccountTest < ActiveSupport::TestCase
  def build_account(attrs = {})
    pubkey = SecureRandom.hex(32)
    user = User.create!(pubkey_hex: pubkey, npub: Nostr::KeyConverter.hex_to_npub(pubkey))
    user.accounts.build({ pubkey_hex: SecureRandom.hex(32) }.merge(attrs))
  end

  def with_guard_enabled
    previous = Rails.application.config.x.allow_private_network_urls
    Rails.application.config.x.allow_private_network_urls = false
    yield
  ensure
    Rails.application.config.x.allow_private_network_urls = previous
  end

  test "rejects a blossom server pointing at an internal address" do
    with_guard_enabled do
      account = build_account
      account.blossom_server = "http://169.254.169.254/latest/meta-data/"

      assert_not account.valid?
      assert_match(/blossom/i, account.errors.full_messages.join)
    end
  end

  test "rejects a plaintext blossom server" do
    with_guard_enabled do
      account = build_account
      account.blossom_server = "http://blossom.example.com"

      assert_not account.valid?
    end
  end

  test "accepts a blank blossom server (uses the global default)" do
    account = build_account
    account.blossom_server = ""

    assert account.valid?, account.errors.full_messages.join(", ")
  end

  test "rejects an over-long personality" do
    account = build_account(personality: "x" * (Account::MAX_PERSONALITY_LENGTH + 1))

    assert_not account.valid?
    assert_includes account.errors.attribute_names, :personality
  end

  # This validation postdates the table, so records already violate it. Applying
  # it to every write meant a grandfathered account could not re-pair its signer
  # — pairing is a recovery path and must not be gated on an unrelated field.
  test "a grandfathered over-long personality does not block unrelated updates" do
    account = build_account
    account.save!
    account.update_column(:personality, "x" * (Account::MAX_PERSONALITY_LENGTH + 500))
    account.reload

    assert account.apply_signer(fake_auth_session).save,
           "re-pairing must not be blocked: #{account.errors.full_messages.to_sentence}"
    assert account.messaging_enabled?
  end

  test "editing the personality is still validated" do
    account = build_account
    account.save!
    account.update_column(:personality, "x" * (Account::MAX_PERSONALITY_LENGTH + 500))

    account.reload.personality = "y" * (Account::MAX_PERSONALITY_LENGTH + 1)
    assert_not account.valid?
  end

  # Same shape of problem: the Blossom check does live DNS, so an unresolvable
  # media host would otherwise block reconnecting a signer.
  test "an unrelated settings change does not re-run the blossom url check" do
    with_guard_enabled do
      account = build_account
      account.save!
      account.update_column(:settings, { "blossom_server" => "https://gone.invalid" })

      assert account.reload.apply_signer(fake_auth_session).save,
             "re-pairing must not re-validate an unchanged media server"
    end
  end

  test "changing the blossom server is still validated" do
    with_guard_enabled do
      account = build_account
      account.save!
      account.blossom_server = "http://169.254.169.254/latest/meta-data/"

      assert_not account.valid?
    end
  end

  # --- NIP-17 messaging capability -------------------------------------------

  # A signer cannot be asked which permissions it granted, so the stamped version
  # is the only signal that an account was paired with the DM permission set.
  test "an account paired before DM permissions existed needs a re-pair" do
    account = build_account(signer_pubkey: SecureRandom.hex(32), app_privkey: SecureRandom.hex(32))

    assert_not account.messaging_capable?
    assert account.needs_messaging_repair?
  end

  test "an account paired with the current permission set is messaging capable" do
    account = build_account(
      signer_pubkey: SecureRandom.hex(32), app_privkey: SecureRandom.hex(32),
      dm_perms_version: Nostr::AuthService::PERMISSIONS_VERSION
    )

    assert account.messaging_capable?
    assert_not account.needs_messaging_repair?
  end

  # No signer at all is a different problem from an out-of-date signer, and the UI
  # must not nag about re-pairing something that was never paired.
  test "an account with no signer does not need a messaging re-pair" do
    account = build_account

    assert_not account.messaging_capable?
    assert_not account.needs_messaging_repair?
  end

  test "applying a signer stamps the permission version" do
    account = build_account
    account.apply_signer(fake_auth_session)

    assert_equal Nostr::AuthService::PERMISSIONS_VERSION, account.dm_perms_version
    assert account.messaging_capable?
  end

  # Without this the whole inbound pipeline stays gated off: both the poller and
  # the live supervisor select on Account.messaging, so an account that is
  # "capable" but not "enabled" silently never fetches anything.
  test "applying a signer turns messaging on" do
    account = build_account
    assert_not account.messaging_enabled?

    account.apply_signer(fake_auth_session)

    assert account.messaging_enabled?
    assert_includes Account.messaging, account.tap(&:save!)
  end

  # Re-pairing is the remedy for a signer that refused a DM operation, so it must
  # clear the warning rather than leaving it up forever.
  test "applying a signer clears a previous denial marker" do
    account = build_account
    account.settings = { "dm_capability" => "denied" }
    assert account.messaging_denied?

    account.apply_signer(fake_auth_session)

    assert_not account.messaging_denied?
  end

  # Emanator does not create identities: an account's real DM inbox is whatever
  # kind 10050 it already published from another client. Inventing a default here
  # would overrule the user and point us at the wrong relays.
  test "dm relay prefs are empty until the user chooses, with no configured default" do
    assert_equal [], build_account.dm_relay_prefs
  end

  test "suggested dm relays are offered with their auth properties" do
    suggestions = Account.suggested_dm_relays

    assert suggestions.any?, "the inbox picker needs something to offer"
    assert suggestions.all? { |s| s[:url].present? }
    # Whether a relay enforces NIP-42 decides if third parties can enumerate the
    # account's incoming wraps, so the picker must be able to say.
    assert suggestions.any? { |s| s[:auth] == true }
    assert suggestions.any? { |s| s[:auth] == false }
  end

  # These URLs are user input that the server then opens sockets to, so an
  # unfiltered value is an SSRF primitive. Literal public IPs are used here
  # deliberately: UrlGuard skips DNS for a literal address, which keeps the test
  # hermetic instead of depending on a live lookup.
  test "dm relay prefs drop unsafe relays" do
    with_guard_enabled do
      account = build_account
      account.dm_relay_prefs = [ "wss://93.184.216.34", "ws://127.0.0.1:7777", "  " ]

      assert_equal [ "wss://93.184.216.34" ], account.dm_relay_prefs
    end
  end

  # NIP-17 asks for a small list because every sender must publish to all of it.
  test "dm relay prefs are capped" do
    account = build_account
    account.dm_relay_prefs = (1..(DmRelayList::MAX_RELAYS + 3)).map { |i| "wss://198.51.100.#{i}" }

    assert_equal DmRelayList::MAX_RELAYS, account.dm_relay_prefs.size
  end

  test "dm relay prefs deduplicate" do
    account = build_account
    account.dm_relay_prefs = [ "wss://93.184.216.34", "wss://93.184.216.34" ]

    assert_equal [ "wss://93.184.216.34" ], account.dm_relay_prefs
  end

  # The warning survived the bug that caused it being fixed, told the user to
  # change a signer setting that was already correct, and offered no way to
  # dismiss it. A success on the relay it names has to clear it.
  test "a successful relay authentication clears the blocked warning" do
    account = build_account
    account.save!
    account.mark_relay_auth_blocked!("auth.nostr1.com")
    assert account.relay_auth_blocked?

    account.clear_relay_auth_blocked!("auth.nostr1.com")

    assert_not account.reload.relay_auth_blocked?
    assert_nil account.settings["amber_auth_blocked_relay"]
  end

  # With an Amber whitelist containing relay A but not relay B, A succeeds on
  # every poll while B stays silently rejected — and B's rejection is cached for
  # hours, so it does not re-assert itself. A success elsewhere clearing the
  # warning would hide it for exactly as long as the problem persists.
  test "a success on a different relay does not clear the warning" do
    account = build_account
    account.save!
    account.mark_relay_auth_blocked!("inbox.nostr.wine")

    account.clear_relay_auth_blocked!("auth.nostr1.com")

    assert account.reload.relay_auth_blocked?
    assert_equal "inbox.nostr.wine", account.settings["amber_auth_blocked_relay"]
  end

  test "clearing an unset warning is a no-op" do
    account = build_account
    account.save!

    assert_nothing_raised { account.clear_relay_auth_blocked!("auth.nostr1.com") }
    assert_not account.relay_auth_blocked?
  end

  private

  def fake_auth_session
    Struct.new(:authenticated_pubkey, :relay_urls, :temp_pubkey, :temp_privkey)
      .new(SecureRandom.hex(32), [ "wss://relay.example" ], SecureRandom.hex(32), SecureRandom.hex(32))
  end
end
