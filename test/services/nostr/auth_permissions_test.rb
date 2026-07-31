# frozen_string_literal: true

require_relative "../../test_helper"

# The pairing permission string is the single point where NIP-17 messaging can
# fail *silently*: a missing entry produces a phone prompt on every message, or an
# auto-rejected request and an empty inbox, with nothing in our logs saying why.
# Amber's parser also drops malformed entries without complaint. Hence these
# assertions on the literal string.
class NostrAuthPermissionsTest < ActiveSupport::TestCase
  def permissions = Nostr::AuthService::PERMISSIONS.split(",")

  # Amber's NostrConnectUtils removes any permission whose type is "sign_event"
  # with no kind, so a bare entry grants nothing rather than everything.
  def test_no_bare_sign_event_entry
    refute_includes permissions, "sign_event",
                    "Amber silently discards a kindless sign_event entry"
  end

  # Kinds 13/14/15/1059 are NOT in Amber's "basic" auto-approve set. Without
  # sign_event:13 every outbound DM raises a prompt on the user's phone.
  def test_the_seal_kind_is_requested
    assert_includes permissions, "sign_event:13"
  end

  # Two nip44_decrypt calls per inbound gift wrap, one nip44_encrypt per seal.
  def test_nip44_encrypt_and_decrypt_are_requested
    assert_includes permissions, "nip44_encrypt"
    assert_includes permissions, "nip44_decrypt"
  end

  # Reading legacy threads needs the decrypt half.
  def test_nip04_decrypt_is_requested_for_legacy_threads
    assert_includes permissions, "nip04_decrypt"
  end

  # The legacy send fallback exists only for recipients with no kind 10050, who
  # cannot receive NIP-17 at all. Encryption happens in the signer, so we need the
  # RPC grant plus the kind — there is no local NIP-04 encryption in this codebase.
  def test_the_legacy_send_fallback_permissions_are_requested
    assert_includes permissions, "nip04_encrypt"
    assert_includes permissions, "sign_event:4"
  end

  def test_supporting_kinds_are_requested
    assert_includes permissions, "sign_event:30078", "NIP-RS read state"
    assert_includes permissions, "sign_event:22242", "NIP-42 relay auth"
  end

  # The whole string becomes a QR code, and past ~600 characters phone cameras
  # start failing to scan it — so an entry we never exercise is not free.
  # sign_event:10050 goes back in when there is a UI that publishes one.
  def test_no_permission_is_requested_for_a_capability_with_no_caller
    refute_includes permissions, "sign_event:10050",
                    "nothing reaches DmRelayListService#publish_own! yet"
  end

  # Rumors are unsigned by design and gift wraps are signed locally with a
  # throwaway key, so asking for these would be requesting authority we never use.
  def test_no_permissions_are_requested_for_locally_signed_or_unsigned_events
    refute_includes permissions, "sign_event:14", "rumors are unsigned"
    refute_includes permissions, "sign_event:15", "rumors are unsigned"
    refute_includes permissions, "sign_event:1059", "gift wraps are signed with an ephemeral key"
    refute_includes permissions, "sign_event:5", "we skip the optional NIP-09 read-state cleanup"
  end

  # Existing capabilities must survive the messaging additions: dropping one would
  # break scheduled posts for every account that re-pairs.
  def test_the_pre_messaging_permissions_are_all_still_present
    %w[
      get_public_key sign_event:1 sign_event:3 sign_event:6 sign_event:7
      sign_event:10000 sign_event:24242
    ].each { |permission| assert_includes permissions, permission }
  end

  def test_every_entry_is_a_bare_method_or_method_with_a_numeric_kind
    permissions.each do |permission|
      assert_match(/\A[a-z0-9_]+(:\d+)?\z/, permission, "#{permission.inspect} will not parse")
    end
  end

  # The whole string goes into a nostrconnect:// URI that is rendered as a QR
  # code. Amber's URI parser is also fragile about "=" inside values, so keep
  # entries plain.
  def test_the_string_stays_scannable_and_free_of_awkward_characters
    assert_operator Nostr::AuthService::PERMISSIONS.length, :<, 400
    refute_match(/[=\s]/, Nostr::AuthService::PERMISSIONS)
  end

  # A phone camera starts struggling well before the QR spec's limit. 632
  # characters (QR version 28, 129x129 modules) was already unscannable in
  # practice; this keeps the whole pairing URI comfortably below that.
  def test_the_pairing_uri_stays_scannable
    uri = Nostr::AuthService.new.generate_connect_uri[:uri]

    assert_operator uri.length, :<, 560, "pairing QR is getting too dense to scan"
  end

  # `,` and `:` are left unencoded to save ~50 characters of %2C/%3A. They are
  # legal in a query per RFC 3986 and are exactly what Amber's parser splits on —
  # but the value still has to survive a standard decode.
  def test_the_permissions_survive_url_decoding_unencoded_separators
    uri = Nostr::AuthService.new.generate_connect_uri[:uri]
    encoded = URI.parse(uri).query[/perms=([^&]*)/, 1]

    assert_equal Nostr::AuthService::PERMISSIONS, CGI.unescape(encoded)
    refute_includes encoded, "%2C"
    refute_includes encoded, "%3A"
  end

  # Bumping PERMISSIONS without bumping the version leaves already-paired accounts
  # believing they hold grants they do not have.
  def test_the_permissions_version_covers_the_messaging_set
    assert_operator Nostr::AuthService::PERMISSIONS_VERSION, :>=, 3
  end
end
