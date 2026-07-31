# frozen_string_literal: true

require_relative "../../test_helper"
require_relative "../../jobs/job_test_helper"

# NIP-42, against a real socket.
#
# Worth testing carefully because the failure is invisible: the DM inbox relays
# that actually honour NIP-17's metadata-protection SHOULD (auth.nostr1.com,
# inbox.nostr.wine) simply refuse to serve kind 1059 to an unauthenticated
# client, so a bug here reads as "this account has no messages".
class NostrRelayAuthTest < ActiveSupport::TestCase
  include NostrTestHelper
  include JobTestHelper
  include CacheHelper
  include FakeRelay

  def setup
    @pubkey, @privkey = keypair
  end

  # --- the pure bits ------------------------------------------------------------

  def test_the_auth_event_carries_the_relay_and_challenge_tags
    event = Nostr::RelayAuth.build_unsigned(
      relay_url: "wss://inbox.example/", challenge: "abc123", pubkey: @pubkey
    )

    assert_equal Nostr::RelayAuth::AUTH_KIND, event["kind"]
    assert_includes event["tags"], [ "relay", "wss://inbox.example" ]
    assert_includes event["tags"], [ "challenge", "abc123" ]
    # inbox.nostr.wine caps forward skew at 300s, so never future-date.
    assert_operator event["created_at"], :<=, Time.now.to_i
  end

  def test_the_relay_tag_is_canonicalised
    assert_equal "wss://inbox.example", Nostr::RelayAuth.canonical_url("wss://inbox.example/")
    assert_equal "wss://inbox.example:7777", Nostr::RelayAuth.canonical_url("wss://inbox.example:7777")
  end

  # `restricted:` means we authenticated with the WRONG key — retrying is
  # pointless. `auth-required:` means try again after authenticating.
  def test_close_reasons_are_classified
    assert_equal :auth_required, Nostr::RelayAuth.classify("auth-required: we can't serve DMs to unauthenticated users")
    assert_equal :restricted, Nostr::RelayAuth.classify("restricted: not your events")
    assert_equal :other, Nostr::RelayAuth.classify("rate-limited")
  end

  def test_a_refusal_is_remembered_for_longer_than_a_success
    assert_operator Nostr::RelayAuth::CACHE_TTL_REJECTED, :>, Nostr::RelayAuth::CACHE_TTL_OK,
                    "an Amber whitelist problem must not re-prompt every poll"
  end

  # --- the handshake, over a real socket ----------------------------------------

  def test_an_auth_required_subscription_is_authenticated_and_re_sent
    url = auth_demanding_relay

    events = Nostr::RelayQuery.run(url, { "kinds" => [ 1059 ] }, timeout: 5, verify: false, auth: signer)

    assert_equal [ "wrapped" ], events.map { |e| e["id"] }

    auth_message = relay_messages_of("AUTH").sole
    signed = auth_message[1]
    assert_equal Nostr::RelayAuth::AUTH_KIND, signed["kind"]
    assert_includes signed["tags"], [ "challenge", "the-challenge" ]
    assert Nostr::EventValidator.valid?(signed, kind: Nostr::RelayAuth::AUTH_KIND, author: @pubkey)

    # A CLOSED destroys the subscription, so authenticating alone is not enough —
    # the REQ has to go out again, under a fresh subscription id.
    reqs = relay_messages_of("REQ")
    assert_equal 2, reqs.size, "the REQ must be re-sent after authenticating"
    assert_not_equal reqs[0][1], reqs[1][1]
  end

  def test_the_relay_is_remembered_as_requiring_auth
    url = auth_demanding_relay
    Nostr::RelayQuery.run(url, { "kinds" => [ 1059 ] }, timeout: 5, verify: false, auth: signer)

    assert Nostr::RelayAuth.requires_auth?(url),
           "so the next connection can authenticate up front instead of being rejected first"
  end

  # Without an auth callback the behaviour must be exactly what it always was.
  def test_a_query_with_no_auth_callback_just_closes
    url = auth_demanding_relay

    events = Nostr::RelayQuery.run(url, { "kinds" => [ 1059 ] }, timeout: 5, verify: false)

    assert_empty events
    assert_empty relay_messages_of("AUTH")
    assert_equal 1, relay_messages_of("REQ").size
  end

  # Authenticated with the wrong key: a hard failure, never retried.
  def test_a_restricted_close_does_not_attempt_authentication
    url = with_relay do |socket, message|
      next unless message[0] == "REQ"
      send_text(socket, [ "AUTH", "the-challenge" ].to_json)
      send_text(socket, [ "CLOSED", message[1], "restricted: not your events" ].to_json)
    end

    events = Nostr::RelayQuery.run(url, { "kinds" => [ 1059 ] }, timeout: 5, verify: false, auth: signer)

    assert_empty events
    assert_empty relay_messages_of("AUTH")
  end

  # Amber auto-rejects kind 22242 for relays missing from a non-empty whitelist;
  # the signer returning nil must end the attempt, not hang it.
  def test_a_signer_that_refuses_ends_the_attempt
    url = auth_demanding_relay

    events = Nostr::RelayQuery.run(
      url, { "kinds" => [ 1059 ] }, timeout: 5, verify: false, auth: ->(*_) { nil }
    )

    assert_empty events
    assert_equal 1, relay_messages_of("REQ").size
  end

  def test_a_relay_rejecting_the_auth_event_does_not_resubscribe
    url = with_relay do |socket, message|
      case message[0]
      when "REQ"
        send_text(socket, [ "AUTH", "the-challenge" ].to_json)
        send_text(socket, [ "CLOSED", message[1], "auth-required: authenticate first" ].to_json)
      when "AUTH"
        send_text(socket, [ "OK", message[1]["id"], false, "invalid: bad signature" ].to_json)
      end
    end

    events = Nostr::RelayQuery.run(url, { "kinds" => [ 1059 ] }, timeout: 5, verify: false, auth: signer)

    assert_empty events
    assert_equal 1, relay_messages_of("REQ").size, "a rejected AUTH must not trigger a re-subscription"
  end

  private

  # Mimics strfry: AUTH on connect, the same challenge again with the rejection,
  # and events only after a successful AUTH.
  def auth_demanding_relay
    authenticated = false

    with_relay do |socket, message|
      case message[0]
      when "REQ"
        if authenticated
          send_text(socket, [ "EVENT", message[1], { "id" => "wrapped", "kind" => 1059 } ].to_json)
          send_text(socket, [ "EOSE", message[1] ].to_json)
        else
          send_text(socket, [ "AUTH", "the-challenge" ].to_json)
          send_text(socket, [ "CLOSED", message[1], "auth-required: you must auth" ].to_json)
        end
      when "AUTH"
        authenticated = true
        send_text(socket, [ "OK", message[1]["id"], true, "" ].to_json)
      end
    end
  end

  def signer
    lambda do |relay_url, challenge|
      unsigned = Nostr::RelayAuth.build_unsigned(relay_url: relay_url, challenge: challenge, pubkey: @pubkey)
      unsigned["id"] = Nostr::EventValidator.event_id(unsigned)
      unsigned["sig"] = Schnorr.sign([ unsigned["id"] ].pack("H*"), [ @privkey ].pack("H*")).encode.unpack1("H*")
      unsigned
    end
  end
end
