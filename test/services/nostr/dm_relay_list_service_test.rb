# frozen_string_literal: true

require_relative "../../test_helper"
require_relative "../../jobs/job_test_helper"

# The service that decides whether a private message can be delivered at all.
# A wrong answer here either blocks a send that would have worked, or pushes the
# user onto the legacy NIP-04 downgrade for no reason.
class NostrDmRelayListServiceTest < ActiveSupport::TestCase
  include NostrTestHelper
  include JobTestHelper
  include CacheHelper

  def setup
    @service = Nostr::DmRelayListService.new
    @pubkey = keypair.first
  end

  def test_a_published_list_is_stored_and_deliverable
    with_relay_events([ relay_list_event([ "wss://inbox.example", "wss://second.example" ]) ]) do
      @service.fetch!(@pubkey)
    end

    list = DmRelayList.for_pubkey(@pubkey)
    assert_equal [ "wss://inbox.example", "wss://second.example" ], list.relays
    assert list.deliverable?
    refute list.missing?
  end

  def test_publish_targets_prefers_the_recipients_own_inbox
    with_relay_events([ relay_list_event([ "wss://inbox.example" ]) ]) do
      targets = @service.publish_targets(@pubkey)

      assert_equal [ "wss://inbox.example" ], targets.relays
      assert_equal :inbox, targets.tier
      assert targets.compliant?, "a published 10050 is the only compliant tier"
    end
  end

  # No 10050: fall back to where their client actually connects, and label it so
  # the UI can stop short of claiming delivery.
  def test_publish_targets_falls_back_to_nip65_read_relays
    fetcher = Object.new
    fetcher.define_singleton_method(:fetch_relay_list) { |_pk| { write: [], read: [ "wss://their-public.example" ] } }
    fetcher.define_singleton_method(:fetch_write_relays) { |_pk| [] }

    stub_class_method(Nostr::RelayListFetcher, :new, ->(*_a) { fetcher }) do
      with_relay_events([]) do
        targets = @service.publish_targets(@pubkey)

        assert_equal [ "wss://their-public.example" ], targets.relays
        assert_equal :nip65, targets.tier
        refute targets.compliant?
      end
    end

    assert DmRelayList.for_pubkey(@pubkey).missing?
  end

  # No relay lists at all: popular relays are the last resort. Never empty, so a
  # send is never silently published to nowhere the way Coracle does it.
  def test_publish_targets_falls_back_to_popular_relays_as_a_last_resort
    with_relay_events([]) do
      targets = @service.publish_targets(@pubkey)

      assert_equal :fallback, targets.tier
      assert targets.any?, "publishing to zero relays would look sent and never arrive"
      configured = Rails.application.config_for(:emanator).dig(:nostr, :fallback_dm_relays)
      assert (targets.relays & configured).any?
    end
  end

  # A 10050 that exists but lists nothing usable is the same situation as none.
  def test_a_list_with_no_usable_relays_counts_as_missing
    with_relay_events([ relay_list_event([]) ]) { @service.fetch!(@pubkey) }

    assert DmRelayList.for_pubkey(@pubkey).missing?
    refute DmRelayList.for_pubkey(@pubkey).deliverable?
  end

  # The negative must only be recorded after BOTH lookup phases have failed:
  # indexers first, then the pubkey's own NIP-65 write relays, where the outbox
  # model says their 10050 legitimately lives.
  def test_the_outbox_phase_runs_when_indexers_have_nothing
    outbox_relay = "wss://their-outbox.example"
    queried = []

    stub_class_method(Nostr::RelayListFetcher, :new, ->(*_a) { fake_relay_list_fetcher(outbox_relay) }) do
      stub_class_method(Nostr::RelayQuery, :run, lambda { |relay_url, *_a, **_k|
        queried << relay_url
        relay_url == outbox_relay ? [ relay_list_event([ "wss://found.example" ]) ] : []
      }) { @service.fetch!(@pubkey) }
    end

    assert_includes queried, outbox_relay, "must fall back to the pubkey's own write relays"
    assert_equal [ "wss://found.example" ], DmRelayList.for_pubkey(@pubkey).relays
    refute DmRelayList.for_pubkey(@pubkey).missing?
  end

  # H4: a 10050 is attacker-supplied and the server opens sockets to whatever it
  # names.
  def test_unsafe_relays_are_dropped_from_a_published_list
    with_guard_enabled do
      with_relay_events([ relay_list_event([ "wss://93.184.216.34", "ws://127.0.0.1:7777" ]) ]) do
        @service.fetch!(@pubkey)
      end
    end

    assert_equal [ "wss://93.184.216.34" ], DmRelayList.for_pubkey(@pubkey).relays
  end

  def test_more_relays_than_the_cap_are_truncated
    urls = (1..(DmRelayList::MAX_RELAYS + 4)).map { |i| "wss://relay#{i}.example" }
    with_relay_events([ relay_list_event(urls) ]) { @service.fetch!(@pubkey) }

    assert_equal DmRelayList::MAX_RELAYS, DmRelayList.for_pubkey(@pubkey).relays.size
  end

  # Kind 10050 is replaceable: an older copy arriving from a lagging relay must
  # not roll back a newer list.
  def test_an_older_event_does_not_overwrite_a_newer_list
    with_relay_events([ relay_list_event([ "wss://new.example" ], created_at: Time.now.to_i) ]) do
      @service.fetch!(@pubkey)
    end
    DmRelayList.for_pubkey(@pubkey).update!(fetched_at: 1.week.ago)

    with_relay_events([ relay_list_event([ "wss://old.example" ], created_at: 1.day.ago.to_i) ]) do
      @service.fetch!(@pubkey)
    end

    assert_equal [ "wss://new.example" ], DmRelayList.for_pubkey(@pubkey).relays
  end

  # Kind 10050 is replaceable, so different relays can hold different versions.
  # Taking the first relay to answer is a race; take the newest event.
  def test_the_newest_list_wins_across_relays
    old_event = relay_list_event([ "wss://old.example" ], created_at: 3.days.ago.to_i)
    new_event = relay_list_event([ "wss://new.example" ], created_at: Time.now.to_i)

    # Each relay answers with a different version.
    answers = [ [ old_event ], [ new_event ], [] ]
    stub_class_method(Nostr::RelayQuery, :run, ->(*_a, **_k) { answers.shift || [] }) do
      @service.fetch!(@pubkey)
    end

    assert_equal [ "wss://new.example" ], DmRelayList.for_pubkey(@pubkey).relays
  end

  # One slow or unreachable relay must not push a lookup past the point where the
  # caller gives up and calls it a definitive negative.
  def test_a_slow_relay_does_not_serialise_the_whole_lookup
    calls = 0
    stub_class_method(Nostr::RelayQuery, :run, lambda { |*_a, **_k|
      calls += 1
      sleep 0.4
      []
    }) do
      # Monotonic clock rather than Benchmark: benchmark is no longer a default
      # gem in Ruby 4.0.
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      @service.fetch!(@pubkey)
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

      assert_operator calls, :>, 1, "several relays should have been asked"
      assert_operator elapsed, :<, calls * 0.4, "relays were queried one after another"
    end
  end

  def test_resolve_uses_the_cache_and_does_not_requery
    with_relay_events([ relay_list_event([ "wss://inbox.example" ]) ]) { @service.fetch!(@pubkey) }

    stub_class_method(Nostr::RelayQuery, :run, ->(*_a, **_k) { flunk "a fresh list must not be re-queried" }) do
      assert_equal [ "wss://inbox.example" ], @service.resolve(@pubkey).relays
    end
  end

  def test_a_malformed_pubkey_is_rejected_without_any_relay_call
    stub_class_method(Nostr::RelayQuery, :run, ->(*_a, **_k) { flunk "must not query for a bad pubkey" }) do
      assert_nil @service.fetch!("not-a-pubkey")
    end
  end

  # --- the receive side is deliberately wider than the send side ---------------

  def test_inbox_relays_union_the_10050_the_nip65_read_relays_and_the_defaults
    account = build_account
    account.update!(read_relays: [ "wss://my-nip65-read.example" ])
    DmRelayList.create!(pubkey_hex: account.pubkey_hex, relays: [ "wss://my-10050.example" ], fetched_at: Time.current)

    relays = @service.inbox_relays_for(account)

    # Several clients deliver wraps outside the recipient's 10050, so reading
    # narrowly would silently miss messages.
    assert_includes relays, "wss://my-10050.example"
    assert_includes relays, "wss://my-nip65-read.example"
    assert_includes relays, Rails.application.config_for(:emanator).dig(:nostr, :relays).first
  end

  def test_inbox_relays_are_capped_and_deduplicated
    account = build_account
    account.update!(read_relays: (1..20).map { |i| "wss://r#{i}.example" })

    relays = @service.inbox_relays_for(account)

    assert_operator relays.size, :<=, Nostr::DmRelayListService::MAX_INBOX_RELAYS
    assert_equal relays.uniq, relays
  end

  # The reason 0xchat and Keychat users can reach us at all. Neither client
  # consults our kind 10050 before deciding where to publish a wrap addressed to
  # us — Keychat has no notion of 10050 whatsoever — so a message can be perfectly
  # compliant, addressed to us, and land only on a relay we never nominated.
  def test_inbox_relays_always_include_the_cross_client_discovery_relays
    account = build_account
    account.update!(read_relays: [ "wss://my-nip65-read.example" ])
    DmRelayList.create!(pubkey_hex: account.pubkey_hex, relays: [ "wss://my-10050.example" ], fetched_at: Time.current)

    relays = @service.inbox_relays_for(account)
    discovery = Rails.application.config_for(:emanator).dig(:nostr, :dm_discovery_relays)

    assert discovery.present?, "the discovery list must not be empty or this feature is off"
    discovery.each { |url| assert_includes relays, url }
  end

  # The cap truncates the tail and the discovery relays sit at the tail, so a
  # busy account must not silently lose exactly the relays added to make those
  # clients reachable.
  def test_discovery_relays_survive_an_account_with_a_long_read_list
    account = build_account
    account.update!(read_relays: (1..20).map { |i| "wss://r#{i}.example" })
    DmRelayList.create!(pubkey_hex: account.pubkey_hex,
                        relays: (1..6).map { |i| "wss://inbox#{i}.example" }, fetched_at: Time.current)

    relays = @service.inbox_relays_for(account)
    discovery = Rails.application.config_for(:emanator).dig(:nostr, :dm_discovery_relays)

    assert_operator relays.size, :<=, Nostr::DmRelayListService::MAX_INBOX_RELAYS
    assert_equal "wss://inbox1.example", relays.first, "the account's own inbox still comes first"
    discovery.each { |url| assert_includes relays, url }
  end

  # --- observed relays are appended to the send side, never substituted --------

  def test_observed_relays_are_appended_to_a_published_inbox
    with_relay_events([ relay_list_event([ "wss://inbox.example" ]) ]) do
      targets = @service.publish_targets(@pubkey, observed: [ "wss://seen-here.example" ])

      assert_equal [ "wss://inbox.example", "wss://seen-here.example" ], targets.relays
      assert_equal [ "wss://seen-here.example" ], targets.observed
      # An observation says where they publish, not that they advertised an
      # inbox — so it must not upgrade or downgrade how the UI describes delivery.
      assert_equal :inbox, targets.tier
    end
  end

  def test_an_observed_relay_already_in_the_inbox_is_not_duplicated
    with_relay_events([ relay_list_event([ "wss://inbox.example" ]) ]) do
      targets = @service.publish_targets(@pubkey, observed: [ "wss://inbox.example" ])

      assert_equal [ "wss://inbox.example" ], targets.relays
      assert_empty targets.observed
    end
  end

  # A gift wrap opens a socket to whatever this list says, and the list is built
  # from relay-supplied event content. (A loopback address is not the case to
  # assert on: UrlGuard deliberately tolerates private networks outside
  # production, so it would pass here and fail on the server.)
  def test_an_unsafe_observed_relay_is_dropped
    with_relay_events([ relay_list_event([ "wss://inbox.example" ]) ]) do
      targets = @service.publish_targets(@pubkey, observed: [ "http://not-a-relay.example" ])

      assert_equal [ "wss://inbox.example" ], targets.relays
      assert_empty targets.observed
    end
  end

  # Relay lists write a trailing slash and our config does not, so a plain uniq
  # saw two relays and we opened two sockets to the same host — receiving every
  # gift wrap twice.
  def test_a_trailing_slash_does_not_make_a_second_relay
    account = build_account
    account.update!(read_relays: [ "wss://dup.example" ])
    DmRelayList.create!(pubkey_hex: account.pubkey_hex, relays: [ "wss://dup.example/" ], fetched_at: Time.current)

    relays = @service.inbox_relays_for(account)

    assert_equal 1, relays.count { |r| r.include?("dup.example") }
    refute relays.any? { |r| r.end_with?("/") }
  end

  private

  def relay_list_event(urls, created_at: Time.now.to_i)
    {
      "kind" => Nostr::Nip17::RELAY_LIST_KIND, "pubkey" => @pubkey, "content" => "",
      "created_at" => created_at, "id" => SecureRandom.hex(32),
      "tags" => urls.map { |url| [ "relay", url ] }
    }
  end

  def with_relay_events(events, &block)
    stub_class_method(Nostr::RelayQuery, :run, ->(*_a, **_k) { events }, &block)
  end

  def fake_relay_list_fetcher(write_relay)
    fetcher = Object.new
    fetcher.define_singleton_method(:fetch_write_relays) { |_pubkey| [ write_relay ] }
    fetcher
  end

  def with_guard_enabled
    previous = Rails.application.config.x.allow_private_network_urls
    Rails.application.config.x.allow_private_network_urls = false
    yield
  ensure
    Rails.application.config.x.allow_private_network_urls = previous
  end
end
