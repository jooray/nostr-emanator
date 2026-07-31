# frozen_string_literal: true

require_relative "../../test_helper"
require_relative "../../jobs/job_test_helper"

# NIP-RS read state. The interesting property is the merge rule — a grow-only max
# register — which is what lets two devices publish concurrently without any
# coordination and without ever fighting over a cursor.
class MessagingReadStateServiceTest < ActiveSupport::TestCase
  include NostrTestHelper
  include JobTestHelper
  include CacheHelper

  def setup
    @account = messaging_account
    @peer = keypair.first
    @conversation = build_conversation
    @service = Messaging::ReadStateService.new(@account)
  end

  def test_marking_read_records_the_cursor_and_debounces_publishing
    now = Time.current
    @service.mark_read(@conversation, now)

    slot = @account.read_state_slots.own_slot.sole
    assert_equal now.to_i, slot.context_map[@peer]
    assert slot.dirty?, "the cursor must be queued for publishing"
    assert_operator slot.publish_after, :>, now, "publishing is debounced, not immediate"
  end

  # Never lower a cursor: a device that is behind must not rewind one ahead of it,
  # or read state would flap forever between devices.
  def test_marking_read_with_an_older_timestamp_does_not_rewind
    @service.mark_read(@conversation, Time.current)
    @account.read_state_slots.own_slot.sole.update!(dirty: false)

    @service.mark_read(@conversation, 2.hours.ago)

    refute @account.read_state_slots.own_slot.sole.dirty?, "an older cursor is not a change"
  end

  # 1:1 threads use the bare peer pubkey — the spec's own suggestion, and the best
  # chance of accidental interop. Groups and legacy threads are namespaced so they
  # cannot collide with it.
  def test_context_ids_distinguish_direct_group_and_legacy_threads
    assert_equal @peer, @service.context_id(@conversation)

    group = build_conversation(participants: [ @account.pubkey_hex, @peer, keypair.first ])
    assert_equal "nip17:#{group.participants_key}", @service.context_id(group)

    legacy = build_conversation(protocol: "nip04")
    assert_equal "nip04:#{@peer}", @service.context_id(legacy)
  end

  def test_the_own_slot_is_created_once_and_reused
    first = @service.own_slot
    assert_equal first.id, @service.own_slot.id
    assert_equal 1, @account.read_state_slots.own_slot.count
    assert first.own?
  end

  # Another device's cursor, merged in, must move our local conversation forward.
  def test_a_peer_slots_cursor_is_applied_to_local_conversations
    read_at = 1.hour.ago
    @conversation.update!(unread_count: 5)
    older = add_inbound_message(sort_at: read_at - 10.minutes)
    newer = add_inbound_message(sort_at: read_at + 10.minutes)

    with_slot_events([ slot_event("otherdevice", { @peer => read_at.to_i }) ]) { @service.sync! }

    @conversation.reload
    assert_equal read_at.to_i, @conversation.last_read_at.to_i
    # Only the message that arrived after the other device read remains unread.
    assert_equal 1, @conversation.unread_count
    assert older.present? && newer.present?
  end

  def test_a_peer_cursor_behind_our_own_is_ignored
    @conversation.update!(last_read_at: Time.current, unread_count: 0)

    with_slot_events([ slot_event("otherdevice", { @peer => 3.days.ago.to_i }) ]) { @service.sync! }

    assert_equal 0, @conversation.reload.unread_count
  end

  # Two installations writing to one replaceable coordinate would clobber each
  # other, so a client_id mismatch on OUR slot rotates us to a fresh one.
  def test_a_conflicting_client_id_on_our_own_slot_rotates_the_slot
    slot = @service.own_slot
    original_id = slot.slot_id

    with_slot_events([ slot_event("someone-elses-client", { @peer => Time.current.to_i }, slot_id: original_id) ]) do
      @service.sync!
    end

    assert_not_equal original_id, @account.read_state_slots.own_slot.sole.slot_id
  end

  def test_imported_slots_are_recorded_as_peers_not_as_our_own
    with_slot_events([ slot_event("otherdevice", { @peer => Time.current.to_i }) ]) { @service.sync! }

    imported = @account.read_state_slots.peers.sole
    refute imported.own?
    assert_equal "otherdevice", imported.client_id
  end

  def test_publishing_signs_a_kind_30078_with_the_slot_and_topic_tags
    @service.mark_read(@conversation, Time.current)

    published = capture_publish { @service.publish! }

    assert_equal ReadStateSlot::KIND, published[:event]["kind"]
    tags = published[:event]["tags"]
    assert_includes tags, [ "d", @account.read_state_slots.own_slot.sole.d_tag ]
    # The topic tag exists so relays can filter our blobs without dumping every
    # kind-30078 we own.
    assert_includes tags, [ "t", ReadStateSlot::TOPIC_TAG ]
  end

  def test_publishing_marks_the_slot_clean
    @service.mark_read(@conversation, Time.current)
    capture_publish { @service.publish! }

    refute @account.read_state_slots.own_slot.sole.dirty?
  end

  def test_nothing_is_published_when_there_is_no_cursor
    stub_class_method(Nostr::EventPublisherService, :new, ->(*_a, **_k) { flunk "nothing to publish" }) do
      with_signer { assert_nil @service.publish! }
    end
  end

  private

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

  def build_conversation(participants: nil, protocol: "nip17")
    participants ||= [ @account.pubkey_hex, @peer ]
    @account.conversations.create!(
      user: @account.user, protocol: protocol,
      participants_key: SecureRandom.hex(32),
      participant_pubkeys: participants.map(&:downcase),
      peer_pubkey: participants.size == 2 ? @peer : nil
    )
  end

  def add_inbound_message(sort_at:)
    @conversation.messages.create!(
      account: @account, user: @account.user, rumor_id: SecureRandom.hex(32),
      sender_pubkey: @peer, direction: "inbound", status: "received",
      sort_at: sort_at, rumor_created_at: sort_at, content: "hi"
    )
  end

  # A slot blob as it comes off a relay: NIP-44 self-encrypted under the account's
  # own key, which is what the stubbed signer decrypts.
  def slot_event(client_id, contexts, slot_id: ReadStateSlot.generate_slot_id)
    payload = { "v" => 1, "client_id" => client_id, "contexts" => contexts }
    {
      "kind" => ReadStateSlot::KIND, "pubkey" => @account.pubkey_hex,
      "created_at" => Time.now.to_i, "id" => SecureRandom.hex(32),
      "tags" => [ [ "d", "#{ReadStateSlot::D_TAG_PREFIX}#{slot_id}" ], [ "t", ReadStateSlot::TOPIC_TAG ] ],
      "content" => Nostr::Nip44.encrypt(
        Nostr::Nip44.conversation_key(@account_privkey, @account.pubkey_hex), JSON.generate(payload)
      )
    }
  end

  def with_slot_events(events, &block)
    fetcher = Object.new
    fetcher.define_singleton_method(:fetch_events) { |_filter| events }
    stub_class_method(Nostr::EventFetcher, :new, ->(*_a, **_k) { fetcher }) { with_signer(&block) }
  end

  # Signer stand-in: self-encrypt/decrypt and sign with the account's real key.
  def with_signer(&block)
    privkey = @account_privkey
    pubkey = @account.pubkey_hex
    rpc = Object.new
    rpc.define_singleton_method(:call) do |method, params|
      case method
      when "nip44_encrypt" then Nostr::Nip44.encrypt(Nostr::Nip44.conversation_key(privkey, params[0]), params[1])
      when "nip44_decrypt" then Nostr::Nip44.decrypt(Nostr::Nip44.conversation_key(privkey, params[0]), params[1])
      when "sign_event"
        event = JSON.parse(params[0])
        event["id"] = Nostr::EventValidator.event_id(event)
        event["sig"] = Schnorr.sign([ event["id"] ].pack("H*"), [ privkey ].pack("H*")).encode.unpack1("H*")
        JSON.generate(event)
      else raise "unexpected method #{method}"
      end
    end
    assert_equal pubkey, @account.pubkey_hex

    stub_class_method(Nostr::Nip46Rpc, :open, ->(*_a, **_k, &blk) { blk.call(rpc) }, &block)
  end

  def capture_publish(&block)
    call = nil
    publisher = Object.new
    publisher.define_singleton_method(:publish) do |event, relays:, **opts|
      call = { event: event, relays: relays, opts: opts }
      relays.index_with { :ok }
    end

    stub_class_method(Nostr::EventPublisherService, :new, ->(*_a, **_k) { publisher }) do
      with_slot_events([], &block)
    end
    call
  end
end
