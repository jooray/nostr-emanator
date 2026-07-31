# frozen_string_literal: true

require_relative "../../test_helper"
require_relative "../../jobs/job_test_helper"

# The live gift-wrap listener, against a real socket.
#
# The property that matters most is that it never blocks on the signer: a
# decrypt costs 200 ms at minimum and up to 120 s if a human has to tap, and
# blocking here would stop us reading the socket and silently drop events. So it
# only records wraps and wakes the decrypt job.
class NostrDmSupervisorTest < ActiveSupport::TestCase
  include NostrTestHelper
  include JobTestHelper
  include CacheHelper
  include FakeRelay
  include ActiveJob::TestHelper

  def setup
    @account = messaging_account
  end

  def test_it_subscribes_for_gift_wraps_addressed_to_the_account
    url = relay_serving([])
    run_supervisor(url)

    req = relay_messages_of("REQ").first
    assert req, "the supervisor never subscribed"
    assert_equal [ Nostr::Nip17::WRAP_KIND ], req[2]["kinds"]
    assert_equal [ @account.pubkey_hex ], req[2]["#p"]
  end

  def test_an_inbound_wrap_is_recorded_in_the_ledger
    wrap = gift_wrap_for(@account.pubkey_hex)
    url = relay_serving([ wrap ])

    run_supervisor(url, expect_wraps: true)

    stored = @account.gift_wraps.sole
    assert_equal wrap["id"], stored.wrap_id
    assert_equal "pending", stored.status
    assert_equal wrap, stored.wrap_event
  end

  def test_recording_a_wrap_wakes_the_decrypt_job
    url = relay_serving([ gift_wrap_for(@account.pubkey_hex) ])

    assert_enqueued_with(job: DecryptGiftWrapsJob) { run_supervisor(url, expect_wraps: true) }
  end

  # The supervisor must never call the signer. If it did, one slow decrypt would
  # stall the socket and lose events.
  def test_it_never_touches_the_signer
    url = relay_serving([ gift_wrap_for(@account.pubkey_hex) ])

    stub_class_method(Nostr::Nip46Rpc, :open, ->(*_a, **_k) { flunk "the supervisor must not decrypt inline" }) do
      stub_class_method(Nostr::EventSignerService, :new, ->(*_a) { flunk "no signing on the read path" }) do
        run_supervisor(url, expect_wraps: true)
      end
    end

    assert_equal 1, @account.gift_wraps.count
  end

  # The ledger's unique key is what makes decryption once-only, so redelivery
  # from another relay must not create a second row or a second job.
  def test_a_redelivered_wrap_is_not_recorded_twice
    wrap = gift_wrap_for(@account.pubkey_hex)
    url = relay_serving([ wrap, wrap ])

    run_supervisor(url, expect_wraps: true)

    assert_equal 1, @account.gift_wraps.count
  end

  # A gift wrap is signed by a throwaway key, so the author cannot be checked —
  # but the id, the signature and the p-tag can, and a wrap for somebody else
  # must not be filed as ours.
  #
  # Both rejection tests send a valid wrap AFTER the bad one and wait for it. That
  # turns "nothing was recorded" from a timing guess into proof: the good wrap
  # arriving means the bad one was definitely seen and dropped.
  def test_a_wrap_addressed_to_someone_else_is_ignored
    assert_only_the_sentinel_is_recorded(gift_wrap_for(keypair.first))
  end

  def test_a_forged_wrap_is_ignored
    forged = gift_wrap_for(@account.pubkey_hex)
    forged["content"] = "tampered after signing"

    assert_only_the_sentinel_is_recorded(forged)
  end

  def test_an_account_without_messaging_permissions_is_not_subscribed
    @account.update!(dm_perms_version: nil)
    url = relay_serving([])

    run_supervisor(url)

    assert_empty relay_messages_of("REQ")
  end

  # A relay we cannot authenticate to was reconnected every ~16 seconds forever in
  # production: the auth attempt itself outlasts STABLE_CONNECTION, so the backoff
  # reset every round and the failure was never remembered.
  def test_a_relay_that_never_sends_a_challenge_is_not_retried_in_a_hot_loop
    Nostr::RelayAuth.remember_requires_auth!("ws://127.0.0.1:1", true)
    url = with_relay # accepts the connection, never sends AUTH

    stub_class_method(Nostr::RelayAuth, :requires_auth?, ->(*_a) { true }) do
      stub_class_method(Nostr::EventSignerService, :new, ->(*_a) { flunk "must not sign without a challenge" }) do
        run_supervisor(url, until_condition: -> { Nostr::RelayAuth.rejected?(url, @account.pubkey_hex) })
      end
    end

    # The failure is remembered, so the next attempt short-circuits instead of
    # reconnecting and waiting for a challenge all over again.
    assert Nostr::RelayAuth.rejected?(url, @account.pubkey_hex)
    assert_empty relay_messages_of("REQ"), "nothing may be subscribed without authenticating"
  end

  # Remembering the rejection is not enough on its own: the socket was still
  # being opened on every backoff cycle, so the relay saw a fresh handshake every
  # ~15 seconds regardless.
  def test_a_known_rejected_relay_is_not_even_reconnected_to
    url = with_relay
    Nostr::RelayAuth.remember_result!(url, @account.pubkey_hex, :rejected)

    stub_class_method(Nostr::RelayAuth, :requires_auth?, ->(*_a) { true }) do
      run_supervisor(url, until_condition: -> { false }, timeout: 3)
    end

    assert_equal 0, relay_handshakes.size,
                 "a relay we know we cannot authenticate to must not be reconnected to"
  end

  # A NIP-42 relay sends its challenge unprompted on connect; we must sign THAT
  # one. The challenge used to live in an instance variable shared by every
  # connection thread, so concurrent handshakes clobbered each other and auth
  # failed against a relay that works perfectly when probed alone.
  def test_the_relay_challenge_is_signed_and_the_subscription_follows
    signed = []
    # A NIP-42 relay pushes the challenge unprompted; the client sends nothing
    # until it arrives.
    url = with_relay(on_connect: ->(socket) { send_text(socket, [ "AUTH", "the-challenge" ].to_json) }) do |socket, message|
      case message[0]
      when "AUTH"
        signed << message[1]
        send_text(socket, [ "OK", message[1]["id"], true, "" ].to_json)
      when "REQ"
        send_text(socket, [ "EOSE", message[1] ].to_json)
      end
    end

    stub_class_method(Nostr::RelayAuth, :requires_auth?, ->(*_a) { true }) do
      with_signing_signer do
        run_supervisor(url, until_condition: -> { relay_messages_of("REQ").any? })
      end
    end

    event = signed.first
    assert event, "the client never authenticated"
    assert_equal Nostr::RelayAuth::AUTH_KIND, event["kind"]
    assert_includes event["tags"], [ "challenge", "the-challenge" ],
                    "the signed event must carry the challenge this relay issued"
    assert relay_messages_of("REQ").any?, "authenticating must be followed by subscribing"
  end

  # Auth binds a socket to one pubkey, so those connections cannot be shared;
  # relays that do not demand it share one socket per relay.
  def test_connection_keys_separate_authenticated_relays_but_share_plain_ones
    plain = Nostr::DmSupervisor::Target.new(
      account_id: 1, pubkey_hex: "a" * 64, relay_url: "wss://plain.example", requires_auth: false
    )
    other_account_same_relay = Nostr::DmSupervisor::Target.new(
      account_id: 2, pubkey_hex: "b" * 64, relay_url: "wss://plain.example", requires_auth: false
    )
    authed = Nostr::DmSupervisor::Target.new(
      account_id: 1, pubkey_hex: "a" * 64, relay_url: "wss://auth.example", requires_auth: true
    )
    authed_other = Nostr::DmSupervisor::Target.new(
      account_id: 2, pubkey_hex: "b" * 64, relay_url: "wss://auth.example", requires_auth: true
    )

    assert_equal plain.key, other_account_same_relay.key, "plain relays share one socket"
    assert_not_equal authed.key, authed_other.key, "a NIP-42 socket is bound to one pubkey"
  end

  private

  # Sends `rejectable` followed by a known-good wrap; only the good one may land.
  def assert_only_the_sentinel_is_recorded(rejectable)
    sentinel = gift_wrap_for(@account.pubkey_hex)
    url = relay_serving([ rejectable, sentinel ])

    run_supervisor(url, expect_wraps: true)

    assert_equal [ sentinel["id"] ], @account.gift_wraps.pluck(:wrap_id)
  end

  def messaging_account
    account = build_account(signer: false)
    pair = ::Nostr::Keygen.new.generate_key_pair
    account.update!(
      signer_pubkey: SecureRandom.hex(32), app_pubkey: pair.public_key.to_s,
      app_privkey: pair.private_key.to_s, messaging_enabled: true,
      dm_perms_version: Nostr::AuthService::PERMISSIONS_VERSION
    )
    account
  end

  # A real, valid kind-1059 signed by a throwaway key, as the protocol requires.
  def gift_wrap_for(recipient)
    sender_pub, sender_priv = keypair
    rumor = Nostr::Nip17.build_rumor(
      kind: Nostr::Nip17::CHAT_KIND, content: "hi", sender_pubkey: sender_pub, recipients: [ recipient ]
    )
    sealed = Nostr::Nip44.encrypt(Nostr::Nip44.conversation_key(sender_priv, recipient), JSON.generate(rumor))
    seal = Nostr::Nip17.build_seal(sealed_content: sealed, sender_pubkey: sender_pub)
    seal["id"] = Nostr::EventValidator.event_id(seal)
    seal["sig"] = Schnorr.sign([ seal["id"] ].pack("H*"), [ sender_priv ].pack("H*")).encode.unpack1("H*")

    Nostr::Nip17.build_wrap(seal: seal, recipient_pubkey: recipient)
  end

  def relay_serving(events)
    with_relay do |socket, message|
      next unless message[0] == "REQ"

      events.each { |event| send_text(socket, [ "EVENT", message[1], event ].to_json) }
    end
  end

  # Signs kind 22242 the way the real signer would, so the challenge round-trip
  # can be asserted end to end.
  def with_signing_signer(&block)
    pubkey, privkey = keypair
    @account.update_columns(pubkey_hex: pubkey)
    signer = Object.new
    signer.define_singleton_method(:request_signature) do |_account, unsigned|
      event = unsigned.dup
      event["id"] = Nostr::EventValidator.event_id(event)
      event["sig"] = Schnorr.sign([ event["id"] ].pack("H*"), [ privkey ].pack("H*")).encode.unpack1("H*")
      event
    end

    stub_class_method(Nostr::EventSignerService, :new, ->(*_a) { signer }, &block)
  end

  # Point the inbox resolution at the fake relay, run one short cycle, and stop
  # deterministically rather than waiting out a deadline.
  def run_supervisor(url, expect_wraps: false, until_condition: nil, timeout: 8)
    resolver = Object.new
    resolver.define_singleton_method(:inbox_relays_for) { |_account| [ url ] }

    stub_class_method(Nostr::DmRelayListService, :new, ->(*_a) { resolver }) do
      supervisor = Nostr::DmSupervisor.new(stop_deadline: 10.seconds.from_now)
      thread = Thread.new { supervisor.run }

      if until_condition
        wait_until(timeout: timeout) { instance_exec(&until_condition) }
      else
        subscribed = wait_until(timeout: 3) { relay_messages_of("REQ").any? }
        wait_until(timeout: 3) { @account.gift_wraps.any? } if subscribed && expect_wraps
      end
      # A short settle so anything already on the wire is drained before we stop.
      sleep 0.2

      supervisor.stop!
      thread.join(3)
    end
  end
end
