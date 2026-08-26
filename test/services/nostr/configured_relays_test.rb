# frozen_string_literal: true

require_relative "../../test_helper"

# Every relay read/write path takes its default relay list from
# config/emanator.yml. `config_for` hands back an OrderedOptions, whose `dig`
# symbolizes only the FIRST key — so `dig("nostr", "relays")` silently returns
# nil and each service falls back to its own hardcoded default. That is how the
# whole app spent its life talking to relay.damus.io alone: reads went to one
# relay, and a publish folded in no defaults at all.
#
# The bug is invisible from the outside (a single relay still works, most of the
# time), so it is worth a test rather than a comment.
class NostrConfiguredRelaysTest < ActiveSupport::TestCase
  def configured
    Array(Rails.application.config_for(:emanator).dig(:nostr, :relays))
  end

  test "the config file actually declares relays" do
    assert_operator configured.size, :>, 1, "config/emanator.yml should list several relays"
  end

  test "EventFetcher queries every configured relay" do
    relays = Nostr::EventFetcher.new.instance_variable_get(:@relays)

    configured.each { |url| assert_includes relays, url.chomp("/") }
  end

  test "ProfileFetcher queries every configured relay" do
    relays = Nostr::ProfileFetcher.new.instance_variable_get(:@relays)

    configured.each { |url| assert_includes relays, url.chomp("/") }
  end

  test "RelayListFetcher queries every configured relay" do
    relays = Nostr::RelayListFetcher.new.instance_variable_get(:@relays)

    configured.each { |url| assert_includes relays, url }
  end

  test "EventPublisherService folds the configured relays into a publish" do
    selected = Nostr::EventPublisherService.new.send(:select_relays, [ "wss://account.example" ])

    assert_includes selected, "wss://account.example"
    assert selected.any? { |url| configured.include?(url) },
      "a publish with include_defaults should reach at least one configured relay"
  end
end
