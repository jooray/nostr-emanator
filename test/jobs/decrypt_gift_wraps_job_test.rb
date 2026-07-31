# frozen_string_literal: true

require_relative "../test_helper"
require_relative "job_test_helper"

# Exercises the full inbound path with real crypto: a genuine gift wrap is built
# with Nostr::Nip17, and the stubbed RPC decrypts it the way the signer would.
# Only the signer round-trip is faked.
class DecryptGiftWrapsJobTest < ActiveSupport::TestCase
  include NostrTestHelper
  include JobTestHelper
  include CacheHelper

  def setup
    @account = messaging_account
    @sender_pub, @sender_priv = keypair
  end

  def test_a_gift_wrap_becomes_a_conversation_and_a_message
    store_wrap(content: "hello from the outside")

    with_signer_decrypting { DecryptGiftWrapsJob.perform_now(@account.id) }

    message = Message.sole
    assert_equal "hello from the outside", message.content
    assert_equal @sender_pub, message.sender_pubkey
    assert message.inbound?
    assert_equal "decoded", GiftWrap.sole.status
    assert_equal message.id, GiftWrap.sole.message_id
  end

  def test_the_conversation_records_both_participants_and_a_preview
    store_wrap(content: "a preview of this")

    with_signer_decrypting { DecryptGiftWrapsJob.perform_now(@account.id) }

    conversation = Conversation.sole
    assert_equal [ @account.pubkey_hex, @sender_pub ].map(&:downcase).sort, conversation.participant_pubkeys.sort
    assert_equal @sender_pub, conversation.peer_pubkey
    assert_equal "a preview of this", conversation.last_message_preview
    assert_equal 1, conversation.unread_count
  end

  # An unknown sender must land behind the Requests tab, not in the main inbox.
  def test_an_unknown_sender_lands_in_requests
    store_wrap

    with_signer_decrypting { DecryptGiftWrapsJob.perform_now(@account.id) }

    assert_equal "request", Conversation.sole.classification
  end

  def test_a_followed_sender_lands_in_the_known_inbox
    InteractionsCache.write_contact_list(@account.pubkey_hex, [ @sender_pub ])
    store_wrap

    with_signer_decrypting { DecryptGiftWrapsJob.perform_now(@account.id) }

    assert_equal "known", Conversation.sole.classification
    assert_equal "own_follow", Conversation.sole.classification_reason
  end

  # The same wrap arrives from several relays and jobs get retried; neither may
  # produce a second bubble or spend a second pair of signer round-trips.
  def test_running_twice_produces_one_message
    store_wrap

    with_signer_decrypting do
      DecryptGiftWrapsJob.perform_now(@account.id)
      GiftWrap.sole.update!(status: "pending") # simulate a requeue
      DecryptGiftWrapsJob.perform_now(@account.id)
    end

    assert_equal 1, Message.count
    assert_equal 1, Conversation.count
  end

  # THE impersonation check, end to end: Eve seals honestly but writes someone
  # else's pubkey into the rumor.
  def test_an_impersonating_rumor_is_rejected_and_never_retried
    eve_pub, eve_priv = keypair
    rumor = Nostr::Nip17.build_rumor(
      kind: Nostr::Nip17::CHAT_KIND, content: "send me your keys",
      sender_pubkey: @sender_pub, recipients: [ @account.pubkey_hex ]
    )
    store_wrap(rumor: rumor, signer_pub: eve_pub, signer_priv: eve_priv)

    with_signer_decrypting { DecryptGiftWrapsJob.perform_now(@account.id) }

    assert_equal 0, Message.count
    wrap = GiftWrap.sole
    assert_equal "rejected", wrap.status
    assert_equal "seal_pubkey_mismatch", wrap.last_error
    refute_includes GiftWrap.queue, wrap, "a hostile wrap must never be retried"
  end

  # Retryable: the signer was unreachable, so the wrap stays queued.
  def test_a_signer_failure_leaves_the_wrap_queued
    store_wrap

    with_failing_signer { DecryptGiftWrapsJob.perform_now(@account.id) }

    wrap = GiftWrap.sole
    assert_equal "pending", wrap.status
    assert_equal 1, wrap.attempts
    assert_equal 0, Message.count
  end

  def test_a_wrap_is_abandoned_after_repeated_signer_failures
    store_wrap
    GiftWrap.sole.update!(attempts: GiftWrap::MAX_ATTEMPTS - 1)

    with_failing_signer { DecryptGiftWrapsJob.perform_now(@account.id) }

    assert_equal "undecryptable", GiftWrap.sole.status
  end

  def test_an_account_without_messaging_permissions_is_skipped
    @account.update!(dm_perms_version: nil)
    store_wrap

    with_signer_decrypting { DecryptGiftWrapsJob.perform_now(@account.id) }

    assert_equal "pending", GiftWrap.sole.status
    assert_equal 0, Message.count
  end

  # Bounds how much of a user's phone battery one spam backlog can consume.
  def test_the_daily_budget_stops_further_decryption
    3.times { store_wrap }
    Rails.cache.write("dm_decrypt_budget_#{@account.id}_#{Date.current}", 10_000)

    with_signer_decrypting { DecryptGiftWrapsJob.perform_now(@account.id) }

    assert_equal 0, Message.count
    assert_equal 3, GiftWrap.pending.count
  end

  def test_progress_is_reported_for_the_ui
    store_wrap

    with_signer_decrypting { DecryptGiftWrapsJob.perform_now(@account.id) }

    sync = DmSyncState.for_account(@account)
    assert_equal "idle", sync.status
    assert_equal 1, sync.processed_wraps
  end

  private

  # pending_keypair mints the pair the next build_account will consume, which is
  # how we get hold of the identity private key. In production that key exists
  # only inside the user's signer — here it lets the stub do the decryption the
  # signer would do.
  def messaging_account
    _pubkey, @account_privkey = pending_keypair
    account = build_account(signer: false)
    pair = ::Nostr::Keygen.new.generate_key_pair
    account.update!(
      signer_pubkey: SecureRandom.hex(32),
      app_pubkey: pair.public_key.to_s,
      app_privkey: pair.private_key.to_s,
      messaging_enabled: true,
      dm_perms_version: Nostr::AuthService::PERMISSIONS_VERSION
    )
    account
  end

  # Builds a real gift wrap and files it in the ledger, exactly as the poll job
  # would. Keeps the recipient's private key so the stub can unwrap it.
  def store_wrap(content: "hi", rumor: nil, signer_pub: nil, signer_priv: nil)
    signer_pub ||= @sender_pub
    signer_priv ||= @sender_priv
    rumor ||= Nostr::Nip17.build_rumor(
      kind: Nostr::Nip17::CHAT_KIND, content: content,
      sender_pubkey: signer_pub, recipients: [ @account.pubkey_hex ]
    )

    sealed = Nostr::Nip44.encrypt(
      Nostr::Nip44.conversation_key(signer_priv, @account.pubkey_hex), JSON.generate(rumor)
    )
    seal = Nostr::Nip17.build_seal(sealed_content: sealed, sender_pubkey: signer_pub)
    seal["id"] = Nostr::EventValidator.event_id(seal)
    seal["sig"] = Schnorr.sign([ seal["id"] ].pack("H*"), [ signer_priv ].pack("H*")).encode.unpack1("H*")

    wrap = Nostr::Nip17.build_wrap(seal: seal, recipient_pubkey: @account.pubkey_hex)

    @account.gift_wraps.create!(
      wrap_id: wrap["id"], wrap_created_at: Time.at(wrap["created_at"]).utc,
      seen_at: Time.current, wrap_event: wrap
    )
  end

  # Stands in for Amber: performs the NIP-44 decryption locally with the
  # recipient's key, which is exactly what the signer does remotely.
  def with_signer_decrypting(&block)
    recipient_priv = @account_privkey
    rpc = Object.new
    rpc.define_singleton_method(:call) do |method, params|
      raise "unexpected method #{method}" unless method == "nip44_decrypt"

      Nostr::Nip44.decrypt(Nostr::Nip44.conversation_key(recipient_priv, params[0]), params[1])
    end
    rpc.define_singleton_method(:call_many, &method(:fake_call_many))

    stub_class_method(Nostr::Nip46Rpc, :open, ->(*_a, **_k, &blk) { blk.call(rpc) }, &block)
  end

  def with_failing_signer(&block)
    rpc = Object.new
    rpc.define_singleton_method(:call) { |*| raise Nostr::Nip46Rpc::TimeoutError, "signer offline" }
    rpc.define_singleton_method(:call_many, &method(:fake_call_many))

    stub_class_method(Nostr::Nip46Rpc, :open, ->(*_a, **_k, &blk) { blk.call(rpc) }, &block)
  end

  # Mirrors the real call_many contract: a failing item becomes an Outcome with
  # `error` set rather than raising, so one bad wrap cannot sink the batch. A stub
  # that lied about this would hide the very behaviour the job relies on.
  def fake_call_many(items, **_opts, &block)
    items.map do |item|
      Nostr::Nip46Rpc::Outcome.new(item: item, value: block.call(item), error: nil)
    rescue StandardError => e
      Nostr::Nip46Rpc::Outcome.new(item: item, value: nil, error: e)
    end
  end
end
