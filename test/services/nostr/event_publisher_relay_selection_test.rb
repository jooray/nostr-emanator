# frozen_string_literal: true

require_relative "../../test_helper"

# H4 + M9: the relay list a publish fans out to is filtered (no private /
# plaintext hosts) and capped.
class NostrEventPublisherRelaySelectionTest < ActiveSupport::TestCase
  def with_guard_enabled
    previous = Rails.application.config.x.allow_private_network_urls
    Rails.application.config.x.allow_private_network_urls = false
    yield
  ensure
    Rails.application.config.x.allow_private_network_urls = previous
  end

  def select(relays)
    Nostr::EventPublisherService.new.send(:select_relays, relays)
  end

  test "unsafe relay urls are dropped" do
    with_guard_enabled do
      selected = select([ "ws://127.0.0.1:4869", "wss://169.254.169.254", "wss://1.1.1.1" ])

      assert_includes selected, "wss://1.1.1.1"
      refute selected.any? { |url| url.include?("127.0.0.1") || url.include?("169.254") }
    end
  end

  test "the relay list is capped" do
    relays = (1..30).map { |i| "wss://relay#{i}.example" }

    assert_operator select(relays).size, :<=, Nostr::EventPublisherService::MAX_RELAYS
  end
end
