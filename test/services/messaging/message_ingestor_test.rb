# frozen_string_literal: true

require_relative "../../test_helper"
require_relative "../../jobs/job_test_helper"

class MessagingMessageIngestorTest < ActiveSupport::TestCase
  include NostrTestHelper
  include JobTestHelper
  include CacheHelper

  def setup
    @account = build_account
    @peer = keypair.first
    @ingestor = Messaging::MessageIngestor.new(@account)
  end

  def test_ingesting_creates_the_conversation_and_the_message
    message = @ingestor.ingest(parsed_message(content: "first contact"))

    assert_equal "first contact", message.content
    assert message.inbound?
    conversation = Conversation.sole
    assert_equal @peer, conversation.peer_pubkey
    assert_equal 1, conversation.unread_count
    assert_equal "first contact", conversation.last_message_preview
  end

  # THE duplicate guard. The self-addressed copy of something we sent comes back
  # through our own inbound subscription carrying the same rumor id, and relays
  # re-deliver too. Both must converge on one row.
  def test_the_same_rumor_ingested_twice_produces_one_message
    parsed = parsed_message
    first = @ingestor.ingest(parsed)
    second = @ingestor.ingest(parsed)

    assert first.present?
    assert_nil second, "a rumor we already stored must not produce a second bubble"
    assert_equal 1, Message.count
    assert_equal 1, Conversation.count
  end

  # A message we sent, arriving back as its own self-copy, must not be re-counted
  # as unread or turned into an inbound bubble.
  def test_the_self_copy_of_an_outbound_message_only_backfills_its_wrap
    parsed = parsed_message(sender: @account.pubkey_hex, content: "sent from another client")
    outbound = @ingestor.ingest(parsed)

    assert outbound.outbound?
    assert_equal 0, outbound.conversation.unread_count, "our own message is read by definition"
    assert outbound.conversation.has_replied?, "writing in a thread vouches for it"

    assert_nil @ingestor.ingest(parsed, wrap_id: "b" * 64)
    assert_equal "b" * 64, outbound.reload.wrap_id, "the wrap that carried it is recorded"
    assert_equal 1, Message.count
  end

  def test_unread_counts_accumulate_for_inbound_messages
    3.times { |i| @ingestor.ingest(parsed_message(content: "msg #{i}")) }

    assert_equal 3, Conversation.sole.unread_count
  end

  # History arriving late — older than our read cursor — is not something new to
  # badge.
  def test_a_message_older_than_the_read_cursor_does_not_increment_unread
    @ingestor.ingest(parsed_message(content: "first"))
    conversation = Conversation.sole
    conversation.update!(unread_count: 0, last_read_at: Time.current)

    @ingestor.ingest(parsed_message(content: "old news", created_at: 2.days.ago.to_i))

    assert_equal 0, conversation.reload.unread_count
  end

  # A hostile sender would otherwise pin itself to the top of the inbox forever.
  def test_a_future_dated_rumor_is_clamped_for_ordering_but_displayed_honestly
    future = 4.years.from_now.to_i
    seen_at = Time.current
    message = @ingestor.ingest(parsed_message(created_at: future), seen_at: seen_at)

    assert_equal seen_at.to_i, message.sort_at.to_i
    assert_equal future, message.rumor_created_at.to_i
  end

  def test_a_group_conversation_has_no_single_peer
    third = keypair.first
    @ingestor.ingest(parsed_message(participants: [ @account.pubkey_hex, @peer, third ]))

    conversation = Conversation.sole
    assert_nil conversation.peer_pubkey
    assert conversation.group?
    assert_equal 3, conversation.participant_pubkeys.size
  end

  def test_a_subject_is_applied_to_the_conversation
    @ingestor.ingest(parsed_message(subject: "Launch plan"))

    assert_equal "Launch plan", Conversation.sole.subject
  end

  # Different participant sets are different rooms — NIP-17 has no room id, so a
  # changed membership is a new room with clean history.
  def test_a_different_participant_set_creates_a_separate_conversation
    @ingestor.ingest(parsed_message)
    @ingestor.ingest(parsed_message(participants: [ @account.pubkey_hex, @peer, keypair.first ]))

    assert_equal 2, Conversation.count
  end

  def test_a_legacy_message_lands_in_its_own_protocol_room
    @ingestor.ingest(parsed_message(kind: Message::LEGACY_KIND), protocol: "nip04")
    @ingestor.ingest(parsed_message)

    assert_equal %w[nip04 nip17], Conversation.pluck(:protocol).sort
  end

  def test_an_unknown_sender_is_classified_into_requests
    @ingestor.ingest(parsed_message)

    assert_equal "request", Conversation.sole.classification
  end

  def test_a_followed_sender_is_classified_as_known
    InteractionsCache.write_contact_list(@account.pubkey_hex, [ @peer ])

    @ingestor.ingest(parsed_message)

    assert_equal "known", Conversation.sole.classification
  end

  # The relay a wrap arrived on is the evidence a reply is routed by, and it has
  # to outlive the wrap: decode! drops the cached event and the ledger is swept.
  def test_the_relays_a_wrap_arrived_on_are_copied_onto_the_message
    message = @ingestor.ingest(parsed_message, relays: [ "wss://relay.keychat.io" ])

    assert_equal [ "wss://relay.keychat.io" ], message.relays
  end

  # A re-delivery produces no second bubble, but it does carry a relay we had not
  # seen yet — and dropping it would throw away a route to that peer.
  def test_a_redelivery_from_another_relay_merges_its_relay_in
    parsed = parsed_message
    message = @ingestor.ingest(parsed, relays: [ "wss://a.example" ])

    assert_nil @ingestor.ingest(parsed, relays: [ "wss://b.example" ])
    assert_equal %w[wss://a.example wss://b.example], message.reload.relays
  end

  private

  def parsed_message(sender: nil, content: "hello", participants: nil, subject: nil,
                     created_at: nil, kind: Nostr::Nip17::CHAT_KIND)
    sender ||= @peer
    participants ||= [ @account.pubkey_hex, @peer ]
    participants = participants.map(&:downcase).uniq.sort

    Nostr::Nip17::Message.new(
      kind: kind,
      sender_pubkey: sender.downcase,
      content: content,
      participants: participants,
      participants_key: Nostr::Nip17.participants_key(participants),
      subject: subject,
      reply_to_rumor_id: nil,
      quoted_rumor_id: nil,
      rumor_id: SecureRandom.hex(32),
      rumor_created_at: created_at || Time.current.to_i,
      seal_created_at: Time.current.to_i,
      tags: [ [ "p", @account.pubkey_hex ] ],
      file_metadata: nil,
      pubkey_recovered: false,
      rumor_id_recomputed: false
    )
  end
end
