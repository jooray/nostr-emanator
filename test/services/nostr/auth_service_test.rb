# frozen_string_literal: true

require_relative "../../test_helper"

class NostrAuthServiceTest < Minitest::Test
  include NostrTestHelper

  def test_nip07_proof_is_server_bound_and_cryptographically_verified
    pubkey, privkey = keypair
    challenge = "server-issued-challenge"
    event = signed_event(
      privkey: privkey,
      pubkey: pubkey,
      kind: 22_242,
      content: "Sign in to Emanator",
      tags: [["challenge", challenge], ["domain", "emanator.cypherpunk.today"]]
    )
    service = Nostr::AuthService.new

    assert service.verify_nip07_auth(pubkey, event.to_json, challenge: challenge)
    refute service.verify_nip07_auth(pubkey, event.to_json, challenge: "attacker-challenge")

    event["sig"] = "0" * 128
    refute service.verify_nip07_auth(pubkey, event.to_json, challenge: challenge)
  end

  def test_connect_uri_has_minimal_permissions_and_canonical_url
    data = Nostr::AuthService.new.generate_connect_uri
    query = URI.decode_www_form(URI(data[:uri]).query).to_h

    assert_equal "https://emanator.cypherpunk.today", query["url"]
    assert_equal Nostr::AuthService::PERMISSIONS, query["perms"]
    assert_includes query["perms"].split(","), "sign_event:3"
    assert_includes query["perms"].split(","), "sign_event:10000"
  ensure
    NostrAuthSession.find_by(session_id: data&.dig(:session_id))&.destroy!
  end
end
