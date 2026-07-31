# frozen_string_literal: true

require_relative "../../test_helper"

# End-to-end checks for the consolidated relay clients (EventPublisherService and
# RelayQuery, which backs ProfileFetcher / EventFetcher / RelayListFetcher)
# against a minimal in-process WebSocket relay.
class NostrRelayRoundTripTest < ActiveSupport::TestCase
  include FakeRelay

  # inbox.nostr.wine answers a User-Agent-less handshake with HTTP 403, and the
  # rescue in WebsocketConnection.open turns that into a bare nil — so the header
  # is the difference between "DM inbox relay works" and "silently unreachable".
  def test_handshake_sends_a_user_agent
    url = with_relay { |socket, message| send_text(socket, [ "EOSE", message[1] ].to_json) if message[0] == "REQ" }

    Nostr::RelayQuery.run(url, { "kinds" => [ 0 ] }, timeout: 5, verify: false)

    assert wait_until { relay_handshakes.any? }, "relay never completed a handshake"
    assert_match(/^User-Agent: Emanator /, relay_handshakes.first, "handshake sent no User-Agent")
  end

  def test_a_relay_that_refuses_the_upgrade_is_unreachable_not_a_crash
    refusal = [ "HTTP/1.1 403 Forbidden", "Content-Length: 0", "", "" ].join("\r\n")
    url = with_relay(handshake_response: refusal)

    assert_nil Nostr::RelayQuery.run(url, { "kinds" => [ 0 ] }, timeout: 2)
  end

  def test_publisher_gets_ok_for_its_own_event
    event = { "id" => "a" * 64, "kind" => 1, "content" => "hello" }

    url = with_relay do |socket, message|
      case message[0]
      when "EVENT"
        # An OK for a different event must not answer this publish.
        send_text(socket, [ "OK", "b" * 64, false, "other event" ].to_json)
        send_text(socket, [ "OK", message[1]["id"], true, "" ].to_json)
      end
    end

    assert_equal :ok, Nostr::EventPublisherService.new.send(:publish_to_relay, url, event)
  end

  def test_publisher_reports_rejection
    event = { "id" => "c" * 64, "kind" => 1, "content" => "nope" }

    url = with_relay do |socket, message|
      send_text(socket, [ "OK", message[1]["id"], false, "blocked" ].to_json) if message[0] == "EVENT"
    end

    assert_equal :rejected, Nostr::EventPublisherService.new.send(:publish_to_relay, url, event)
  end

  def test_relay_query_collects_events_until_eose
    url = with_relay do |socket, message|
      next unless message[0] == "REQ"
      sub_id = message[1]
      send_text(socket, [ "EVENT", sub_id, { "id" => "1", "kind" => 0, "content" => "{}" } ].to_json)
      send_text(socket, [ "EVENT", sub_id, { "id" => "2", "kind" => 0, "content" => "{}" } ].to_json)
      send_text(socket, [ "EOSE", sub_id ].to_json)
    end

    # verify: false — these stub events carry no signature; signature checking
    # itself is covered by relay_query_verification_test.rb.
    events = Nostr::RelayQuery.run(url, { "kinds" => [ 0 ] }, timeout: 5, verify: false)
    assert_equal %w[1 2], events.map { |e| e["id"] }
  end

  def test_relay_query_returns_nil_when_the_relay_is_unreachable
    server = TCPServer.new("127.0.0.1", 0)
    port = server.addr[1]
    server.close

    assert_nil Nostr::RelayQuery.run("ws://127.0.0.1:#{port}", { "kinds" => [ 0 ] }, timeout: 1)
  end
end
