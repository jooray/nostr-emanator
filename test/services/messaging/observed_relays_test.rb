# frozen_string_literal: true

require_relative "../../test_helper"
require_relative "../../jobs/job_test_helper"

# Turning "where this peer's messages arrived" into reply targets. Wrong answers
# here either route a reply to a relay the peer never touches, or throw away the
# only route to a Keychat contact — who publishes no kind 10050 at all.
class MessagingObservedRelaysTest < ActiveSupport::TestCase
  include NostrTestHelper
  include JobTestHelper
  include CacheHelper

  def setup
    @account = build_account
    @peer = keypair.first
    @conversation = @account.conversations.create!(
      user: @account.user, participants_key: SecureRandom.hex(32),
      participant_pubkeys: [ @account.pubkey_hex, @peer ].map(&:downcase), peer_pubkey: @peer.downcase
    )
  end

  def test_relays_from_the_peers_inbound_messages_are_returned_newest_first
    inbound(relays: [ "wss://old.example" ], at: 2.days.ago)
    inbound(relays: [ "wss://new.example" ], at: 1.minute.ago)

    assert_equal %w[wss://new.example wss://old.example], Messaging::ObservedRelays.for(@conversation, @peer)
  end

  # Our own outbound wraps go where WE chose to publish them, which says nothing
  # about where the peer is listening.
  def test_our_own_outbound_relays_are_not_treated_as_the_peers
    inbound(relays: [ "wss://theirs.example" ])
    @conversation.messages.create!(
      account: @account, user: @account.user, sender_pubkey: @account.pubkey_hex.downcase,
      direction: "outbound", status: "sent", kind: Nostr::Nip17::CHAT_KIND, content: "hi",
      rumor_id: SecureRandom.hex(32), sort_at: Time.current, relays: [ "wss://ours.example" ]
    )

    assert_equal [ "wss://theirs.example" ], Messaging::ObservedRelays.for(@conversation, @peer)
  end

  # In a group thread each participant is heard on their own relays, and a reply
  # is wrapped per recipient — so mixing them would publish each person's wrap to
  # relays only the others use.
  def test_a_third_partys_relays_are_not_returned_for_this_peer
    inbound(relays: [ "wss://theirs.example" ])
    inbound(relays: [ "wss://someone-else.example" ], sender: keypair.first)

    assert_equal [ "wss://theirs.example" ], Messaging::ObservedRelays.for(@conversation, @peer)
  end

  # Every extra target is one more relay learning that somebody gift-wrapped this
  # pubkey, so the contribution from observation stays small.
  def test_the_result_is_capped
    10.times { |i| inbound(relays: [ "wss://r#{i}.example" ], at: i.minutes.ago) }

    assert_equal Messaging::ObservedRelays::MAX_RELAYS, Messaging::ObservedRelays.for(@conversation, @peer).size
  end

  def test_a_relay_that_refused_our_wraps_is_not_offered_again
    inbound(relays: [ "wss://paywalled.example", "wss://fine.example" ])
    Nostr::RelayWriteBlock.observe!("wss://paywalled.example", :rejected)

    assert_equal [ "wss://fine.example" ], Messaging::ObservedRelays.for(@conversation, @peer)
  end

  # MariaDB types a `json` column as LONGTEXT, so `pluck` hands back the raw
  # string there while SQLite hands back an Array. Production is MariaDB; the
  # test suite is not, so the string path needs asserting directly.
  def test_a_json_column_plucked_as_a_string_is_decoded
    decoded = Messaging::ObservedRelays.send(:rank, [ '["wss://from-mariadb.example"]' ])

    assert_equal [ "wss://from-mariadb.example" ], decoded
  end

  def test_garbage_in_the_column_is_ignored_rather_than_raising
    assert_empty Messaging::ObservedRelays.send(:rank, [ "not json at all", nil ])
  end

  def test_nothing_is_returned_when_the_feature_is_switched_off
    inbound(relays: [ "wss://theirs.example" ])

    stub_class_method(Messaging::ObservedRelays, :enabled?, -> { false }) do
      assert_empty Messaging::ObservedRelays.for(@conversation, @peer)
    end
  end

  private

  def inbound(relays:, at: Time.current, sender: nil)
    @conversation.messages.create!(
      account: @account, user: @account.user, sender_pubkey: (sender || @peer).downcase,
      direction: "inbound", status: "received", kind: Nostr::Nip17::CHAT_KIND, content: "hi",
      rumor_id: SecureRandom.hex(32), rumor_created_at: at, sort_at: at, relays: relays
    )
  end
end
