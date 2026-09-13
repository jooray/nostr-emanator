# frozen_string_literal: true

require "test_helper"

class NostrBunkerUriTest < ActiveSupport::TestCase
  PUBKEY = ("a" * 64).freeze

  # --- routing (deliberately looser than validity) ---------------------------

  test "recognises a well-formed bunker URI" do
    assert Nostr::KeyConverter.bunker_uri?("bunker://#{PUBKEY}?relay=wss://nos.lol")
  end

  # iOS capitalises the first typed character. Routing on a case-sensitive match
  # sent these to the "paste a key" branch, where they died with an unrelated
  # bech32 error instead of a bunker-specific message.
  test "recognises a capitalised scheme and surrounding whitespace" do
    assert Nostr::KeyConverter.bunker_uri?("Bunker://#{PUBKEY}?relay=wss://nos.lol")
    assert Nostr::KeyConverter.bunker_uri?("  bunker://#{PUBKEY}?relay=wss://nos.lol\n")
  end

  # A malformed bunker string is still a bunker string and must report a bunker
  # error, so routing must accept what validation rejects.
  test "routes a malformed bunker string to the bunker branch" do
    assert Nostr::KeyConverter.bunker_uri?("bunker://nonsense")
    assert_nil Nostr::KeyConverter.parse_bunker_uri("bunker://nonsense")
  end

  test "does not claim npub or nostrconnect input" do
    refute Nostr::KeyConverter.bunker_uri?("npub1abc")
    refute Nostr::KeyConverter.bunker_uri?("nostrconnect://#{PUBKEY}?relay=wss://nos.lol")
  end

  # --- parsing ---------------------------------------------------------------

  test "extracts pubkey, relays and secret" do
    uri = "bunker://#{PUBKEY}?relay=wss%3A%2F%2Fnos.lol&relay=wss%3A%2F%2Frelay.primal.net&secret=s3cr3t"

    assert_equal({ pubkey: PUBKEY, relays: ["wss://nos.lol", "wss://relay.primal.net"], secret: "s3cr3t" },
                 Nostr::KeyConverter.parse_bunker_uri(uri))
  end

  test "accepts unescaped relay values, which signers do emit" do
    result = Nostr::KeyConverter.parse_bunker_uri("bunker://#{PUBKEY}?relay=wss://nos.lol")

    assert_equal ["wss://nos.lol"], result[:relays]
  end

  test "treats a missing secret as nil rather than empty string" do
    assert_nil Nostr::KeyConverter.parse_bunker_uri("bunker://#{PUBKEY}?relay=wss://nos.lol")[:secret]
  end

  test "lowercases an uppercased hex pubkey" do
    result = Nostr::KeyConverter.parse_bunker_uri("bunker://#{'A' * 64}?relay=wss://nos.lol")

    assert_equal PUBKEY, result[:pubkey]
  end

  # Without a relay there is nowhere to send the connect request.
  test "rejects a URI with no relay" do
    assert_nil Nostr::KeyConverter.parse_bunker_uri("bunker://#{PUBKEY}")
    assert_nil Nostr::KeyConverter.parse_bunker_uri("bunker://#{PUBKEY}?secret=x")
  end

  test "rejects a pubkey that is not 64 hex characters" do
    assert_nil Nostr::KeyConverter.parse_bunker_uri("bunker://abc?relay=wss://nos.lol")
    assert_nil Nostr::KeyConverter.parse_bunker_uri("bunker://#{'z' * 64}?relay=wss://nos.lol")
  end

  test "returns nil rather than raising on junk" do
    ["", "bunker://", "not a uri", "bunker://%%%?relay=x"].each do |junk|
      assert_nil Nostr::KeyConverter.parse_bunker_uri(junk), "expected nil for #{junk.inspect}"
    end
  end

  # --- session creation ------------------------------------------------------

  test "start_bunker_session pins the signer and unions relays with our own" do
    result = Nostr::AuthService.new.start_bunker_session(
      "bunker://#{PUBKEY}?relay=wss%3A%2F%2Fnos.lol&secret=s3cr3t"
    )

    refute_nil result
    record = NostrAuthSession.find_by(session_id: result[:session_id])
    assert_equal "bunker", record.flow
    assert_equal PUBKEY, record.signer_pubkey
    assert_equal "s3cr3t", record.secret
    assert_includes record.relay_urls, "wss://nos.lol"
    assert_operator record.relay_urls.size, :>, 1
  end

  test "start_bunker_session accepts a URI with no secret" do
    result = Nostr::AuthService.new.start_bunker_session("bunker://#{PUBKEY}?relay=wss://nos.lol")

    refute_nil result
    assert_equal "", NostrAuthSession.find_by(session_id: result[:session_id]).secret
  end

  test "start_bunker_session returns nil for an unusable URI" do
    assert_nil Nostr::AuthService.new.start_bunker_session("bunker://nope")
    assert_nil Nostr::AuthService.new.start_bunker_session("bunker://#{PUBKEY}")
  end

  # A relay URL is an outbound destination chosen by whoever pasted the link.
  # UrlGuard deliberately permits private addresses outside production so a
  # local relay works in development, so pin the production policy to test the
  # thing that actually matters.
  test "start_bunker_session refuses non-public relay destinations in production" do
    previous = Rails.application.config.x.allow_private_network_urls
    Rails.application.config.x.allow_private_network_urls = false

    result = Nostr::AuthService.new.start_bunker_session(
      "bunker://#{PUBKEY}?relay=ws%3A%2F%2F127.0.0.1&relay=ws%3A%2F%2F169.254.169.254"
    )

    if result
      relays = NostrAuthSession.find_by(session_id: result[:session_id]).relay_urls
      refute relays.any? { |r| r.include?("127.0.0.1") || r.include?("169.254") },
             "loopback/link-local relays must never be dialled: #{relays.inspect}"
    end
  ensure
    Rails.application.config.x.allow_private_network_urls = previous
  end

  # nostrconnect's exact-secret check is the only thing binding that handshake
  # to the browser, so a secret remains mandatory there.
  test "nostrconnect sessions still require a secret" do
    session = NostrAuthSession.new(
      session_id: SecureRandom.uuid, flow: "nostrconnect",
      temp_pubkey: PUBKEY, temp_privkey: "b" * 64, secret: "",
      relay_url: ["wss://nos.lol"].to_json, expires_at: 5.minutes.from_now
    )

    refute session.valid?
    assert_includes session.errors.attribute_names, :secret
  end

  test "bunker sessions require a pinned signer" do
    session = NostrAuthSession.new(
      session_id: SecureRandom.uuid, flow: "bunker",
      temp_pubkey: PUBKEY, temp_privkey: "b" * 64, secret: "",
      relay_url: ["wss://nos.lol"].to_json, expires_at: 5.minutes.from_now
    )

    refute session.valid?
    assert_includes session.errors.attribute_names, :signer_pubkey
  end
end
