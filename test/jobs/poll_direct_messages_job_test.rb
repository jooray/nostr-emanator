# frozen_string_literal: true

require_relative "../test_helper"
require_relative "job_test_helper"

# The inbound half of cross-client reach: which relays we ask, and what we
# remember about where each wrap came from.
class PollDirectMessagesJobTest < ActiveSupport::TestCase
  include NostrTestHelper
  include JobTestHelper
  include CacheHelper

  def setup
    @account = messaging_account
    @account.update!(read_relays: [ "wss://my-read.example" ])
    DmRelayList.create!(pubkey_hex: @account.pubkey_hex, relays: [ "wss://my-inbox.example" ],
                        fetched_at: Time.current)
  end

  # The whole point of the discovery relays: neither 0xchat nor Keychat consults
  # our kind 10050 before choosing where to publish a wrap addressed to us.
  def test_the_poll_asks_the_cross_client_discovery_relays
    asked = poll_with({})
    discovery = Rails.application.config_for(:emanator).dig(:nostr, :dm_discovery_relays)

    discovery.each { |url| assert_includes asked, url }
  end

  # Which relay a wrap arrived on is the evidence a reply is routed by. The poll
  # fans out across relays and used to `uniq` on the event id, throwing away
  # every sighting but one.
  def test_a_wrap_seen_on_several_relays_records_all_of_them
    event = wrap_event
    poll_with("wss://my-inbox.example" => [ event ], "wss://relay.keychat.io" => [ event ])

    wrap = GiftWrap.sole
    assert_equal event["id"], wrap.wrap_id
    assert_equal %w[wss://my-inbox.example wss://relay.keychat.io], wrap.relays.sort
  end

  # `since` is one watermark for the whole account, so it is simply wrong for a
  # relay we have only just started listening to: everything already sitting
  # there is older than the watermark and would be skipped forever.
  def test_adding_a_relay_forces_one_deep_rescan
    poll_with({})
    sync = DmSyncState.for_account(@account)
    sync.update!(last_wrap_seen_at: Time.current)
    watermark = sync.since

    @account.update!(read_relays: [ "wss://my-read.example", "wss://newly-added.example" ])
    asked_since = nil
    poll_with({}) { |_relay, filter| asked_since = filter["since"] }

    assert_operator asked_since, :<, watermark, "a new relay must be scanned from further back"
  end

  def test_an_unchanged_relay_set_keeps_the_watermark
    poll_with({})
    sync = DmSyncState.for_account(@account)
    sync.update!(last_wrap_seen_at: Time.current)
    watermark = sync.since

    asked_since = nil
    poll_with({}) { |_relay, filter| asked_since = filter["since"] }

    assert_equal watermark, asked_since
  end

  private

  # Stubs the relay read so each relay answers with its own events, and returns
  # the relays that were actually asked.
  def poll_with(events_by_relay, &probe)
    asked = []
    query = lambda do |relay_url, filter, **_opts|
      asked << relay_url
      probe&.call(relay_url, filter)
      events_by_relay[relay_url] || []
    end

    stub_class_method(Nostr::RelayQuery, :run, query) do
      stub_class_method(Nostr::RelayListFetcher, :new, ->(*_a) { relay_list_fetcher }) do
        PollDirectMessagesJob.perform_now(@account.id)
      end
    end

    asked
  end

  def relay_list_fetcher
    fetcher = Object.new
    fetcher.define_singleton_method(:fetch_relay_list) { |_pk| { write: [], read: [] } }
    fetcher.define_singleton_method(:fetch_write_relays) { |_pk| [] }
    fetcher
  end

  # A real gift wrap: the poll verifies the signature and the recipient p-tag
  # before recording anything, so a hand-rolled hash would be dropped.
  def wrap_event
    seal = { "id" => SecureRandom.hex(32), "pubkey" => keypair.first, "created_at" => Time.now.to_i,
             "kind" => Nostr::Nip17::SEAL_KIND, "tags" => [], "content" => "x", "sig" => "0" * 128 }
    Nostr::Nip17.build_wrap(seal: seal, recipient_pubkey: @account.pubkey_hex)
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
end
