# frozen_string_literal: true

require_relative "../../test_helper"
require_relative "../../jobs/job_test_helper"

class NostrRelayListFetcherTest < ActiveSupport::TestCase
  include NostrTestHelper
  include JobTestHelper

  def setup
    @pubkey = SecureRandom.hex(32)
  end

  # NIP-65: a tag with no marker means the relay is used for both.
  def test_an_unmarked_relay_counts_as_both_read_and_write
    list = fetch_with_tags([ [ "r", "wss://both.example" ] ])

    assert_equal [ "wss://both.example" ], list[:write]
    assert_equal [ "wss://both.example" ], list[:read]
  end

  def test_markers_split_the_list
    list = fetch_with_tags([
      [ "r", "wss://outbox.example", "write" ],
      [ "r", "wss://inbox.example", "read" ]
    ])

    assert_equal [ "wss://outbox.example" ], list[:write]
    assert_equal [ "wss://inbox.example" ], list[:read]
  end

  # The read half is new (it used to be discarded). Publishing must still only
  # ever use the write half.
  def test_fetch_write_relays_still_returns_only_the_write_half
    tags = [ [ "r", "wss://outbox.example", "write" ], [ "r", "wss://inbox.example", "read" ] ]

    assert_equal [ "wss://outbox.example" ], fetch_write_with_tags(tags)
  end

  # H4: a NIP-65 list is attacker-influenced and the server opens sockets to it.
  def test_unsafe_relays_are_dropped_from_both_halves
    with_guard_enabled do
      list = fetch_with_tags([
        [ "r", "wss://93.184.216.34" ],
        [ "r", "ws://127.0.0.1:7777" ],
        [ "r", "ws://169.254.169.254", "read" ]
      ])

      assert_equal [ "wss://93.184.216.34" ], list[:write]
      assert_equal [ "wss://93.184.216.34" ], list[:read]
    end
  end

  def test_duplicate_entries_are_collapsed
    list = fetch_with_tags([ [ "r", "wss://dup.example" ], [ "r", "wss://dup.example", "write" ] ])

    assert_equal [ "wss://dup.example" ], list[:write]
  end

  def test_non_r_tags_are_ignored
    list = fetch_with_tags([ [ "p", SecureRandom.hex(32) ], [ "r", "" ], [ "r", "wss://real.example" ] ])

    assert_equal [ "wss://real.example" ], list[:write]
  end

  def test_a_pubkey_with_no_relay_list_yields_empty_halves
    list = with_relay_events([]) { Nostr::RelayListFetcher.new.fetch_relay_list(@pubkey) }

    assert_equal({ write: [], read: [] }, list)
  end

  def test_a_blank_pubkey_short_circuits
    assert_equal({ write: [], read: [] }, Nostr::RelayListFetcher.new.fetch_relay_list(nil))
  end

  private

  def fetch_with_tags(tags)
    with_relay_events([ relay_list_event(tags) ]) do
      Nostr::RelayListFetcher.new.fetch_relay_list(@pubkey)
    end
  end

  def fetch_write_with_tags(tags)
    with_relay_events([ relay_list_event(tags) ]) do
      Nostr::RelayListFetcher.new.fetch_write_relays(@pubkey)
    end
  end

  def relay_list_event(tags)
    { "kind" => 10_002, "pubkey" => @pubkey, "tags" => tags, "content" => "", "created_at" => Time.now.to_i }
  end

  def with_relay_events(events, &block)
    stub_class_method(Nostr::RelayQuery, :run, ->(*_args, **_opts) { events }, &block)
  end

  def with_guard_enabled
    previous = Rails.application.config.x.allow_private_network_urls
    Rails.application.config.x.allow_private_network_urls = false
    yield
  ensure
    Rails.application.config.x.allow_private_network_urls = previous
  end
end
