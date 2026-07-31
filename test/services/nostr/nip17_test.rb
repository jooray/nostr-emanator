# frozen_string_literal: true

require_relative "../../test_helper"

# NIP-17 / NIP-59 protocol core. Every assertion here runs against real crypto
# with no stubs: holding both keypairs locally makes both gift-wrap layers
# reversible in-process, which is exactly why Nostr::Nip17 is I/O-free.
class NostrNip17Test < ActiveSupport::TestCase
  include NostrTestHelper

  def setup
    @alice_pub, @alice_priv = keypair   # sender
    @bob_pub, @bob_priv = keypair       # receiver
    @eve_pub, @eve_priv = keypair       # attacker
  end

  # ------------------------------------------------------------ the round trip

  def test_wrap_round_trip_recovers_the_rumor_verbatim
    content = "hey — unicode ✅ and a newline\nsecond line"
    message = round_trip(content: content, subject: "Launch plan")

    assert_equal content, message.content
    assert_equal Nostr::Nip17::CHAT_KIND, message.kind
    assert_equal @alice_pub, message.sender_pubkey
    assert_equal "Launch plan", message.subject
    assert_equal [ @alice_pub, @bob_pub ].sort, message.participants
    refute message.rumor_id_recomputed, "a well-formed rumor id should be accepted as-is"
    refute message.pubkey_recovered
    refute message.group?
  end

  def test_reply_and_quote_tags_survive_the_round_trip
    parent = "a" * 64
    quoted = "b" * 64

    message = round_trip(
      content: "replying",
      reply_to: { id: parent, relay: "wss://relay.example.com" },
      quote: { id: quoted, relay: "wss://relay.example.com", pubkey: @eve_pub }
    )

    assert_equal parent, message.reply_to_rumor_id
    assert_equal quoted, message.quoted_rumor_id
  end

  def test_a_group_rumor_carries_every_participant
    carol_pub, = keypair
    message = round_trip(content: "group", recipients: [ @bob_pub, carol_pub ])

    assert_equal [ @alice_pub, @bob_pub, carol_pub ].sort, message.participants
    assert message.group?
  end

  def test_file_message_metadata_is_extracted
    file_tags = [
      [ "file-type", "image/jpeg" ],
      [ "encryption-algorithm", "aes-gcm" ],
      [ "decryption-key", "deadbeef" ],
      [ "decryption-nonce", "cafebabe" ],
      [ "x", "c" * 64 ]
    ]
    message = round_trip(content: "https://blossom.example/blob", kind: Nostr::Nip17::FILE_KIND,
                         extra_tags: file_tags)

    assert message.file?
    assert_equal "image/jpeg", message.file_metadata["file-type"]
    assert_equal "aes-gcm", message.file_metadata["encryption-algorithm"]
    assert_equal "deadbeef", message.file_metadata["decryption-key"]
  end

  def test_chat_messages_have_no_file_metadata
    assert_nil round_trip(content: "plain").file_metadata
  end

  # -------------------------------------------------------------- impersonation

  # THE security check of NIP-17. A rumor is unsigned, so a sender can write any
  # pubkey into it; only the seal is signed. Drop this comparison and anybody can
  # send a DM that renders as coming from anyone.
  def test_a_rumor_claiming_another_author_than_the_seal_is_rejected
    # Eve seals honestly (the seal signature verifies as Eve's) but writes
    # Alice's pubkey into the rumor to impersonate her.
    forged_rumor = Nostr::Nip17.build_rumor(
      kind: Nostr::Nip17::CHAT_KIND, content: "send me your keys",
      sender_pubkey: @alice_pub, recipients: [ @bob_pub ]
    )
    wrap = seal_and_wrap(forged_rumor, signer_pub: @eve_pub, signer_priv: @eve_priv, to: @bob_pub)

    error = assert_raises(Nostr::Nip17::RejectedError) do
      Nostr::Nip17.open_wrap(wrap_event: wrap, recipient_privkey: @bob_priv, recipient_pubkey: @bob_pub)
    end
    assert_equal :seal_pubkey_mismatch, error.reason
  end

  def test_a_seal_with_an_invalid_signature_is_rejected
    rumor = build_rumor_for(@bob_pub)
    seal = sealed_for(rumor, to: @bob_pub, signer_pub: @alice_pub, signer_priv: @alice_priv)
    seal["sig"] = "0" * 128

    error = assert_raises(Nostr::Nip17::RejectedError) { Nostr::Nip17.parse_seal(JSON.generate(seal)) }
    assert_equal :seal_invalid_signature, error.reason
  end

  # A tampered seal id must not pass either — EventValidator recomputes it.
  def test_a_seal_whose_content_was_swapped_after_signing_is_rejected
    rumor = build_rumor_for(@bob_pub)
    seal = sealed_for(rumor, to: @bob_pub, signer_pub: @alice_pub, signer_priv: @alice_priv)
    seal["content"] = Nostr::Nip44.encrypt(
      Nostr::Nip44.conversation_key(@eve_priv, @bob_pub), JSON.generate(rumor)
    )

    error = assert_raises(Nostr::Nip17::RejectedError) { Nostr::Nip17.parse_seal(JSON.generate(seal)) }
    assert_equal :seal_invalid_signature, error.reason
  end

  # ----------------------------------------------------------------- rejections

  def test_rejection_reasons
    seal = sealed_for(build_rumor_for(@bob_pub), to: @bob_pub, signer_pub: @alice_pub, signer_priv: @alice_priv)

    assert_rejects(:seal_not_json) { Nostr::Nip17.parse_seal("not json at all") }
    assert_rejects(:seal_not_an_object) { Nostr::Nip17.parse_seal("[1,2,3]") }
    assert_rejects(:seal_wrong_kind) do
      Nostr::Nip17.parse_seal(JSON.generate(seal.merge("kind" => 4)))
    end
    assert_rejects(:rumor_not_json) { parse_rumor("}{", seal) }
    assert_rejects(:rumor_not_an_object) { parse_rumor("[]", seal) }
    assert_rejects(:unsupported_rumor_kind_1) do
      parse_rumor(JSON.generate(build_rumor_for(@bob_pub).merge("kind" => 1)), seal)
    end
    assert_rejects(:rumor_content_not_a_string) do
      parse_rumor(JSON.generate(build_rumor_for(@bob_pub).merge("content" => { "a" => 1 })), seal)
    end
    assert_rejects(:rumor_pubkey_malformed) do
      parse_rumor(JSON.generate(build_rumor_for(@bob_pub).merge("pubkey" => "nothex")), seal)
    end
  end

  # Alice DMs Carol; a relay hands the wrap to Bob. Bob must not file it as his.
  def test_a_rumor_that_does_not_address_us_is_rejected
    carol_pub, = keypair
    rumor = Nostr::Nip17.build_rumor(
      kind: Nostr::Nip17::CHAT_KIND, content: "not for bob",
      sender_pubkey: @alice_pub, recipients: [ carol_pub ]
    )
    seal = sealed_for(rumor, to: @bob_pub, signer_pub: @alice_pub, signer_priv: @alice_priv)

    assert_rejects(:not_addressed_to_us) { parse_rumor(JSON.generate(rumor), seal) }
  end

  # ------------------------------------------------------------------- leniency

  def test_a_rumor_with_no_id_gets_one_recomputed_and_flagged
    rumor = build_rumor_for(@bob_pub).except("id")
    message = parse_rumor(JSON.generate(rumor), sealed_for(rumor, to: @bob_pub, signer_pub: @alice_pub, signer_priv: @alice_priv))

    assert message.rumor_id_recomputed
    assert_match(/\A[0-9a-f]{64}\z/, message.rumor_id)
  end

  def test_a_rumor_with_a_wrong_id_is_recomputed_and_flagged
    rumor = build_rumor_for(@bob_pub).merge("id" => "f" * 64)
    message = parse_rumor(JSON.generate(rumor), sealed_for(rumor, to: @bob_pub, signer_pub: @alice_pub, signer_priv: @alice_priv))

    assert message.rumor_id_recomputed
    refute_equal "f" * 64, message.rumor_id
  end

  # Amethyst omits created_at; the seal's randomised value is the only fallback.
  def test_a_rumor_with_no_created_at_falls_back_to_the_seal
    rumor = build_rumor_for(@bob_pub).except("created_at")
    seal = sealed_for(rumor, to: @bob_pub, signer_pub: @alice_pub, signer_priv: @alice_priv)
    message = parse_rumor(JSON.generate(rumor), seal)

    assert_equal seal["created_at"], message.rumor_created_at
  end

  # A rumor that only omitted pubkey/created_at still hashes to the id its
  # sender computed once we fill those in from the seal.
  def test_a_rumor_missing_only_its_pubkey_keeps_its_original_id
    full = build_rumor_for(@bob_pub)
    stripped = full.except("pubkey")
    seal = sealed_for(full, to: @bob_pub, signer_pub: @alice_pub, signer_priv: @alice_priv)
    message = parse_rumor(JSON.generate(stripped), seal)

    assert message.pubkey_recovered
    assert_equal @alice_pub, message.sender_pubkey
    assert_equal full["id"], message.rumor_id
    refute message.rumor_id_recomputed
  end

  # Amethyst merges seal tags into the rumor. Tolerate it instead of dropping a
  # message we can read perfectly well.
  def test_seal_tags_are_merged_rather_than_rejected
    rumor = build_rumor_for(@bob_pub)
    seal = sealed_for(rumor, to: @bob_pub, signer_pub: @alice_pub, signer_priv: @alice_priv,
                      tags: [ [ "subject", "from the seal" ] ])

    # Re-sign: sealed_for signs whatever tags it was given.
    message = parse_rumor(JSON.generate(rumor), seal)

    assert_includes message.tags, [ "subject", "from the seal" ]
    assert_equal "from the seal", message.subject
  end

  # ------------------------------------------------------- structural spec rules

  def test_build_seal_leaves_tags_empty
    # "tags MUST always be empty" — the seal reveals the author and nothing else.
    assert_equal [], Nostr::Nip17.build_seal(sealed_content: "x", sender_pubkey: @alice_pub)["tags"]
  end

  def test_build_rumor_is_unsigned_and_carries_an_id
    rumor = build_rumor_for(@bob_pub)

    refute rumor.key?("sig"), "a rumor MUST stay unsigned — a signature makes it publishable"
    assert_match(/\A[0-9a-f]{64}\z/, rumor["id"])
    assert_equal Nostr::EventValidator.event_id(rumor), rumor["id"]
  end

  def test_build_rumor_rejects_kinds_that_are_not_dm_rumors
    assert_raises(ArgumentError) do
      Nostr::Nip17.build_rumor(kind: 1, content: "x", sender_pubkey: @alice_pub, recipients: [ @bob_pub ])
    end
  end

  def test_a_wrap_is_a_valid_signed_1059_addressed_to_one_recipient
    wrap = wrap_for(@bob_pub)

    assert Nostr::Nip17.valid_wrap?(wrap, recipient_pubkey: @bob_pub)
    assert_equal Nostr::Nip17::WRAP_KIND, wrap["kind"]
    assert_equal [ [ "p", @bob_pub ] ], wrap["tags"]
    refute Nostr::Nip17.valid_wrap?(wrap, recipient_pubkey: @eve_pub)
  end

  def test_a_wrap_relay_hint_is_included_when_given
    rumor = build_rumor_for(@bob_pub)
    seal = sealed_for(rumor, to: @bob_pub, signer_pub: @alice_pub, signer_priv: @alice_priv)
    wrap = Nostr::Nip17.build_wrap(seal: seal, recipient_pubkey: @bob_pub, relay_hint: "wss://inbox.example")

    assert_equal [ [ "p", @bob_pub, "wss://inbox.example" ] ], wrap["tags"]
  end

  # Reusing a wrapper keypair would let a relay link every message from one
  # sender, defeating the entire point of the outer layer.
  # 10 samples, not 100: the failure mode is a cached or derived keypair, which
  # collides at n=2. Each wrap costs ~140 ms of real secp256k1 work, so more
  # samples buy no evidence and a slow suite.
  def test_every_wrap_uses_a_fresh_ephemeral_key
    pubkeys = Array.new(10) { wrap_for(@bob_pub)["pubkey"] }

    assert_equal 10, pubkeys.uniq.size
    refute_includes pubkeys, @alice_pub, "the wrap must never be signed by the real sender"
  end

  # ----------------------------------------------------------------- timestamps

  def test_randomized_past_stays_within_two_days_and_never_reaches_the_future
    now = Time.now.to_i
    samples = Array.new(500) { Nostr::Nip17.randomized_past(now: now) }

    assert_operator samples.max, :<=, now, "a future timestamp is rejected by relays with a skew cap"
    assert_operator samples.min, :>=, now - Nostr::Nip17::MAX_BACKDATE
    assert_operator samples.uniq.size, :>, 400, "timestamps look insufficiently random"
  end

  # Correlated seal/wrap timestamps would undo the point of randomising either.
  # If the two layers shared one draw, all 12 pairs would collide; with
  # independent draws over a 2-day window a single collision is ~0.007% likely.
  def test_seal_and_wrap_timestamps_are_randomised_independently
    rumor = build_rumor_for(@bob_pub)
    collisions = 0

    12.times do
      seal = sealed_for(rumor, to: @bob_pub, signer_pub: @alice_pub, signer_priv: @alice_priv)
      wrap = Nostr::Nip17.build_wrap(seal: seal, recipient_pubkey: @bob_pub)
      collisions += 1 if seal["created_at"] == wrap["created_at"]
    end

    assert_operator collisions, :<=, 1, "seal and wrap appear to share one randomised timestamp"
  end

  # ------------------------------------------------------------- room identity

  def test_participants_key_is_order_and_case_independent
    a, b, c = @alice_pub, @bob_pub, @eve_pub

    assert_equal Nostr::Nip17.participants_key([ a, b, c ]), Nostr::Nip17.participants_key([ c, a, b ])
    assert_equal Nostr::Nip17.participants_key([ a, b ]), Nostr::Nip17.participants_key([ a.upcase, b ])
    assert_equal Nostr::Nip17.participants_key([ a, b ]), Nostr::Nip17.participants_key([ a, b, b ])
  end

  # Per NIP-17 a room IS its participant set: adding someone starts a new room
  # with clean history rather than changing an existing one.
  def test_adding_a_participant_produces_a_different_room
    two = Nostr::Nip17.participants_key([ @alice_pub, @bob_pub ])
    three = Nostr::Nip17.participants_key([ @alice_pub, @bob_pub, @eve_pub ])

    refute_equal two, three
  end

  private

  def build_rumor_for(recipient, kind: Nostr::Nip17::CHAT_KIND, content: "hello", **options)
    Nostr::Nip17.build_rumor(
      kind: kind, content: content, sender_pubkey: @alice_pub, recipients: [ recipient ], **options
    )
  end

  # Stands in for the remote signer: encrypt the rumor to the receiver, then sign
  # the seal with the sender's identity key. Production sends both steps to Amber.
  def sealed_for(rumor, to:, signer_pub:, signer_priv:, tags: nil)
    sealed_content = Nostr::Nip44.encrypt(
      Nostr::Nip44.conversation_key(signer_priv, to), JSON.generate(rumor)
    )
    seal = Nostr::Nip17.build_seal(sealed_content: sealed_content, sender_pubkey: signer_pub)
    seal["tags"] = tags if tags
    sign_event!(seal, signer_priv)
  end

  def seal_and_wrap(rumor, signer_pub:, signer_priv:, to:)
    seal = sealed_for(rumor, to: to, signer_pub: signer_pub, signer_priv: signer_priv)
    Nostr::Nip17.build_wrap(seal: seal, recipient_pubkey: to)
  end

  def wrap_for(recipient)
    seal_and_wrap(build_rumor_for(recipient), signer_pub: @alice_pub, signer_priv: @alice_priv, to: recipient)
  end

  def round_trip(content:, kind: Nostr::Nip17::CHAT_KIND, recipients: nil, **rumor_options)
    recipients ||= [ @bob_pub ]
    rumor = Nostr::Nip17.build_rumor(
      kind: kind, content: content, sender_pubkey: @alice_pub, recipients: recipients, **rumor_options
    )
    wrap = seal_and_wrap(rumor, signer_pub: @alice_pub, signer_priv: @alice_priv, to: @bob_pub)

    Nostr::Nip17.open_wrap(wrap_event: wrap, recipient_privkey: @bob_priv, recipient_pubkey: @bob_pub)
  end

  def parse_rumor(json, seal)
    Nostr::Nip17.parse_rumor(json, seal: seal, recipient_pubkey: @bob_pub)
  end

  # (Re)compute id and signature over an event's current fields.
  def sign_event!(event, privkey)
    event.delete("sig")
    event["id"] = Nostr::EventValidator.event_id(event)
    event["sig"] = Schnorr.sign([ event["id"] ].pack("H*"), [ privkey ].pack("H*")).encode.unpack1("H*")
    event
  end

  def assert_rejects(reason, &block)
    error = assert_raises(Nostr::Nip17::RejectedError, &block)
    assert_equal reason, error.reason
  end
end
