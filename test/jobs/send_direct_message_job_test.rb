# frozen_string_literal: true

require_relative "../test_helper"
require_relative "job_test_helper"

class SendDirectMessageJobTest < ActiveSupport::TestCase
  include NostrTestHelper
  include JobTestHelper
  include CacheHelper

  def setup
    @account = messaging_account
    # A real curve point: NIP-44 derives a shared secret against it, so random
    # bytes would fail with "public key not on the curve".
    @peer = keypair.first
    @conversation = build_conversation
    dm_relays_for(@peer, [ "wss://peer-inbox.example" ])
    dm_relays_for(@account.pubkey_hex, [ "wss://my-inbox.example" ])
  end

  def test_a_message_is_sealed_wrapped_and_published_to_both_sides
    message = build_outbound("hello there")

    published = capture_publishes { SendDirectMessageJob.perform_now(message.id) }

    assert_equal "sent", message.reload.status
    # One wrap for the peer, one addressed to ourselves — the self-copy is the
    # only sent-history NIP-17 has.
    assert_equal 2, published.size
    assert published.all? { |p| p[:event]["kind"] == Nostr::Nip17::WRAP_KIND }
  end

  # THE privacy regression guard. select_relays otherwise always folds in the
  # configured defaults, which would publish gift wraps to damus.io/nos.lol and
  # leak who-talks-to-whom to relays the recipient never nominated.
  def test_a_gift_wrap_goes_only_to_the_relays_the_recipient_nominated
    message = build_outbound

    published = capture_publishes { SendDirectMessageJob.perform_now(message.id) }

    peer_publish = published.find { |p| p[:relays] == [ "wss://peer-inbox.example" ] }
    assert peer_publish, "the peer's wrap must go to exactly their kind 10050"
    assert_equal false, peer_publish[:opts][:include_defaults]

    configured = Rails.application.config_for(:emanator).dig(:nostr, :relays)
    published.each do |publish|
      assert_empty (publish[:relays] & configured),
                   "a gift wrap reached a configured default relay: #{publish[:relays].inspect}"
    end
  end

  def test_each_wrap_is_signed_by_a_different_ephemeral_key
    message = build_outbound

    published = capture_publishes { SendDirectMessageJob.perform_now(message.id) }
    authors = published.map { |p| p[:event]["pubkey"] }

    assert_equal 2, authors.uniq.size
    refute_includes authors, @account.pubkey_hex, "a wrap must never be signed by the real sender"
  end

  # Refusing here blocked roughly two thirds of real contacts, and was incoherent
  # beside the kind-4 downgrade we offer instead: a gift wrap on a public relay
  # reveals only that SOMEONE messaged this pubkey, while a kind 4 publishes the
  # whole social-graph edge. It now sends, and records how.
  def test_a_recipient_without_a_dm_inbox_is_sent_to_their_public_relays
    DmRelayList.definitive_negative!(@peer)
    message = build_outbound

    published = capture_publishes(peer_read_relays: [ "wss://their-public.example" ]) do
      SendDirectMessageJob.perform_now(message.id)
    end

    assert_equal "sent", message.reload.status
    assert_equal "nip65", message.delivery_tier
    assert message.best_effort_delivery?, "the bubble must not claim a normal delivery"
    assert published.any? { |p| p[:relays] == [ "wss://their-public.example" ] }
  end

  # No 10050 and no NIP-65 either: popular relays are the last resort. Viable only
  # because every client examined reads kind 1059 across its whole pool.
  def test_a_recipient_with_no_relay_lists_at_all_falls_back_to_popular_relays
    DmRelayList.definitive_negative!(@peer)
    message = build_outbound

    published = capture_publishes(peer_read_relays: []) { SendDirectMessageJob.perform_now(message.id) }

    assert_equal "sent", message.reload.status
    assert_equal "fallback", message.delivery_tier
    configured = Rails.application.config_for(:emanator).dig(:nostr, :fallback_dm_relays)
    assert published.any? { |p| (p[:relays] & configured).any? }
  end

  # A compliant recipient must not be marked best-effort.
  def test_a_recipient_with_a_dm_inbox_is_recorded_as_compliant
    message = build_outbound

    capture_publishes { SendDirectMessageJob.perform_now(message.id) }

    assert_equal "inbox", message.reload.delivery_tier
    refute message.best_effort_delivery?
  end

  # A note-to-self carries no tier at all: our own inbound subscription spans our
  # NIP-65 read relays and the configured defaults, so the self-copy lands where
  # we listen regardless of which tier carried it — a "may not arrive" badge
  # would warn about a delivery that works.
  def test_a_note_to_self_gets_no_delivery_tier
    @conversation = @account.conversations.create!(
      user: @account.user,
      participants_key: SecureRandom.hex(32),
      participant_pubkeys: [ @account.pubkey_hex ]
    )
    message = build_outbound("remember this")

    capture_publishes { SendDirectMessageJob.perform_now(message.id) }

    assert_equal "sent", message.reload.status
    assert_nil message.delivery_tier
    refute message.best_effort_delivery?
  end

  def test_sending_marks_the_conversation_as_replied_and_known
    @conversation.update!(classification: "request", classification_reason: "unclassified")
    message = build_outbound

    capture_publishes { SendDirectMessageJob.perform_now(message.id) }

    @conversation.reload
    assert @conversation.has_replied?
    assert_equal "known", @conversation.classification
    assert_equal "replied", @conversation.classification_reason
  end

  # The self-copy is a nicety; failing to store our own history must not report
  # the message as undelivered.
  def test_a_failed_self_copy_still_counts_as_sent
    message = build_outbound

    capture_publishes(result_for: ->(relays) {
      relays == [ "wss://my-inbox.example" ] ? { relays.first => :error } : { relays.first => :ok }
    }) { SendDirectMessageJob.perform_now(message.id) }

    assert_equal "sent", message.reload.status
  end

  def test_no_relay_accepting_the_peer_wrap_fails_the_message
    message = build_outbound

    capture_publishes(result_for: ->(relays) { { relays.first => :error } }) do
      SendDirectMessageJob.perform_now(message.id)
    end

    assert_equal "failed", message.reload.status
    assert_match(/No relay accepted/, message.error)
  end

  # A signer that alters what it was asked to sign must never be trusted.
  def test_an_altered_seal_is_rejected
    message = build_outbound

    with_signer(tamper: true) { SendDirectMessageJob.perform_now(message.id) }

    assert_equal "failed", message.reload.status
    assert_match(/altered seal/, message.error)
  end

  # A retry of the job must not send the message twice.
  def test_a_second_run_does_not_resend
    message = build_outbound
    capture_publishes { SendDirectMessageJob.perform_now(message.id) }

    published = capture_publishes { SendDirectMessageJob.perform_now(message.id) }

    assert_empty published
    assert_equal "sent", message.reload.status
  end

  # The rumor id is the unique key the row is indexed by; rebuilding it at send
  # time must reproduce it exactly, or the self-copy would arrive as a new message.
  def test_the_rebuilt_rumor_keeps_its_original_id
    message = build_outbound("round trip")

    assert_equal message.rumor_id, Nostr::EventValidator.event_id(message.rumor)
  end

  # --- replying where the message actually came from --------------------------

  # The Keychat case. Keychat has no notion of kind 10050 at all, so a peer using
  # it looks undeliverable to a spec-following sender while in fact listening on
  # five relays. The relay we heard them on is the only accurate route there is.
  def test_a_reply_also_goes_to_the_relay_the_peer_was_heard_on
    inbound_from_peer(relays: [ "wss://relay.keychat.io" ])
    message = build_outbound

    published = capture_publishes { SendDirectMessageJob.perform_now(message.id) }

    peer_publish = published.find { |p| p[:relays].include?("wss://peer-inbox.example") }
    assert_includes peer_publish[:relays], "wss://relay.keychat.io"
    # Appended, not substituted: their published inbox is still the first target.
    assert_equal "wss://peer-inbox.example", peer_publish[:relays].first
  end

  # The observation is about the peer, so it must not follow us into the wrap we
  # address to ourselves — that one belongs on our own inbox.
  def test_the_self_copy_is_not_routed_by_the_peers_observed_relays
    inbound_from_peer(relays: [ "wss://relay.keychat.io" ])
    message = build_outbound

    published = capture_publishes { SendDirectMessageJob.perform_now(message.id) }

    self_publish = published.find { |p| p[:relays].include?("wss://my-inbox.example") }
    refute_includes self_publish[:relays], "wss://relay.keychat.io"
  end

  # An observation says where a peer publishes, not that they advertised an
  # inbox. Letting it claim the compliant tier would make the composer promise a
  # delivery guarantee the recipient never gave.
  def test_observed_relays_do_not_claim_the_compliant_tier
    DmRelayList.find_by(pubkey_hex: @peer.downcase).update!(relays: [], missing: true)
    inbound_from_peer(relays: [ "wss://relay.keychat.io" ])
    message = build_outbound

    capture_publishes { SendDirectMessageJob.perform_now(message.id) }

    assert_equal "observed", message.reload.delivery_tier
    refute_equal "inbox", message.delivery_tier
  end

  # "may not arrive" is the right warning for a guess at popular relays. It is
  # the wrong one once the wrap went to a relay we watched this peer's own
  # messages come in on — which is the entire Keychat case.
  def test_the_badge_stops_claiming_a_reply_may_not_arrive_once_it_went_where_they_were_heard
    DmRelayList.find_by(pubkey_hex: @peer.downcase).update!(relays: [], missing: true)
    inbound_from_peer(relays: [ "wss://relay.keychat.io" ])
    message = build_outbound

    capture_publishes { SendDirectMessageJob.perform_now(message.id) }

    refute_includes message.reload.delivery_note, "may not arrive"
  end

  # If the observed relay refused the wrap, nothing was learned about
  # reachability and the honest label is still the guess we fell back to.
  def test_a_refused_observed_relay_leaves_the_pessimistic_tier_in_place
    DmRelayList.find_by(pubkey_hex: @peer.downcase).update!(relays: [], missing: true)
    inbound_from_peer(relays: [ "wss://paywalled.example" ])
    message = build_outbound

    reject_paywalled = ->(relays) { relays.index_with { |r| r.include?("paywalled") ? :rejected : :ok } }
    capture_publishes(result_for: reject_paywalled) { SendDirectMessageJob.perform_now(message.id) }

    refute_equal "observed", message.reload.delivery_tier
    assert_includes message.delivery_note, "may not arrive"
  end

  # relay.keychat.io advertises a 1-sat Cashu fee on kinds 4 and 1059 and simply
  # is not charging it yet. When that flips, every reply to a Keychat contact
  # would otherwise keep spending an attempt on a relay that will never take it.
  def test_a_relay_that_rejects_our_wrap_is_dropped_from_later_replies
    inbound_from_peer(relays: [ "wss://paywalled.example" ])
    first = build_outbound

    reject_paywalled = ->(relays) { relays.index_with { |r| r.include?("paywalled") ? :rejected : :ok } }
    attempted = capture_publishes(result_for: reject_paywalled) { SendDirectMessageJob.perform_now(first.id) }

    assert attempted.any? { |p| p[:relays].include?("wss://paywalled.example") },
           "the first reply must actually try the observed relay, or this proves nothing"

    second = build_outbound("again")
    published = capture_publishes { SendDirectMessageJob.perform_now(second.id) }

    published.each { |p| refute_includes p[:relays], "wss://paywalled.example" }
  end

  # A timeout says nothing about relay policy. Evicting on one would let a bad
  # afternoon throw away a peer's only working route.
  def test_a_relay_that_merely_times_out_is_kept
    inbound_from_peer(relays: [ "wss://flaky.example" ])
    first = build_outbound

    time_out_flaky = ->(relays) { relays.index_with { |r| r.include?("flaky") ? :timeout : :ok } }
    capture_publishes(result_for: time_out_flaky) { SendDirectMessageJob.perform_now(first.id) }

    second = build_outbound("again")
    published = capture_publishes { SendDirectMessageJob.perform_now(second.id) }

    peer_publish = published.find { |p| p[:relays].include?("wss://peer-inbox.example") }
    assert_includes peer_publish[:relays], "wss://flaky.example"
  end

  private

  # An inbound message from the peer, carrying the relays its gift wrap arrived
  # on — which is what a reply is routed by.
  def inbound_from_peer(relays:)
    @conversation.messages.create!(
      account: @account, user: @account.user, sender_pubkey: @peer.downcase,
      direction: "inbound", status: "received", kind: Nostr::Nip17::CHAT_KIND,
      content: "hi", rumor_id: SecureRandom.hex(32), rumor_created_at: Time.current,
      sort_at: Time.current, relays: relays
    )
  end

  def messaging_account
    _pubkey, @account_privkey = pending_keypair
    account = build_account(signer: false)
    pair = ::Nostr::Keygen.new.generate_key_pair
    account.update!(
      signer_pubkey: SecureRandom.hex(32), app_pubkey: pair.public_key.to_s,
      app_privkey: pair.private_key.to_s, messaging_enabled: true,
      dm_perms_version: Nostr::AuthService::PERMISSIONS_VERSION
    )
    account
  end

  def build_conversation
    @account.conversations.create!(
      user: @account.user,
      participants_key: SecureRandom.hex(32),
      participant_pubkeys: [ @account.pubkey_hex, @peer ].map(&:downcase),
      peer_pubkey: @peer
    )
  end

  def build_outbound(content = "hi")
    Messaging::OutboundBuilder.new(@conversation).build(content: content).message
  end

  def dm_relays_for(pubkey, relays)
    DmRelayList.create!(pubkey_hex: pubkey.downcase, relays: relays, fetched_at: Time.current)
  end

  # Signer stand-in: encrypts with the account's real key and signs seals with it,
  # which is exactly what Amber does remotely.
  def with_signer(tamper: false, on_call: nil, &block)
    privkey = @account_privkey
    pubkey = @account.pubkey_hex
    rpc = Object.new
    rpc.define_singleton_method(:call) do |method, params|
      on_call&.call
      case method
      when "nip44_encrypt"
        Nostr::Nip44.encrypt(Nostr::Nip44.conversation_key(privkey, params[0]), params[1])
      when "sign_event"
        event = JSON.parse(params[0])
        event["content"] = "tampered" if tamper
        event["id"] = Nostr::EventValidator.event_id(event)
        event["sig"] = Schnorr.sign([ event["id"] ].pack("H*"), [ privkey ].pack("H*")).encode.unpack1("H*")
        JSON.generate(event)
      else
        raise "unexpected method #{method}"
      end
    end

    stub_class_method(Nostr::Nip46Rpc, :open, ->(*_a, **_k, &blk) { blk.call(rpc) }, &block)
  end

  # Records every publish so the relay set can be asserted.
  def capture_publishes(result_for: nil, peer_read_relays: [], &block)
    calls = []
    publisher = Object.new
    publisher.define_singleton_method(:publish) do |event, relays:, **opts|
      calls << { event: event, relays: relays, opts: opts }
      result_for ? result_for.call(relays) : relays.index_with { :ok }
    end

    fetcher = Object.new
    fetcher.define_singleton_method(:fetch_relay_list) { |_pk| { write: [], read: peer_read_relays } }
    fetcher.define_singleton_method(:fetch_write_relays) { |_pk| [] }

    stub_class_method(Nostr::EventPublisherService, :new, ->(*_a, **_k) { publisher }) do
      stub_class_method(Nostr::RelayListFetcher, :new, ->(*_a) { fetcher }) do
        with_signer(&block)
      end
    end
    calls
  end
end
