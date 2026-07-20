# frozen_string_literal: true

require_relative "../../test_helper"

# End-to-end checks for the consolidated relay clients (EventPublisherService and
# RelayQuery, which backs ProfileFetcher / EventFetcher / RelayListFetcher)
# against a minimal in-process WebSocket relay.
class NostrRelayRoundTripTest < ActiveSupport::TestCase
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

  private

  # Boot a one-connection WebSocket relay; `handler` receives each parsed client
  # message. Returns the ws:// URL. Torn down when the test process moves on.
  def with_relay(&handler)
    server = TCPServer.new("127.0.0.1", 0)
    port = server.addr[1]

    @threads ||= []
    @servers ||= []
    @servers << server
    @threads << Thread.new do
      socket = server.accept
      handshake(socket)
      loop do
        payload = read_client_frame(socket)
        break unless payload
        message = JSON.parse(payload)
        instance_exec(socket, message, &handler)
      end
    rescue StandardError
      nil
    end

    "ws://127.0.0.1:#{port}"
  end

  def teardown
    @threads&.each(&:kill)
    @servers&.each { |s| s.close rescue nil }
  end

  def handshake(socket)
    request = +""
    request << socket.readpartial(1024) until request.include?("\r\n\r\n")
    key = request[/Sec-WebSocket-Key: (.+)\r\n/, 1]
    accept = Base64.strict_encode64(Digest::SHA1.digest(key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"))
    socket.write([
      "HTTP/1.1 101 Switching Protocols",
      "Upgrade: websocket",
      "Connection: Upgrade",
      "Sec-WebSocket-Accept: #{accept}",
      "", ""
    ].join("\r\n"))
  end

  def read_client_frame(socket)
    header = socket.read(2)
    return nil unless header
    second = header.bytes[1]
    length = second & 0x7F
    length = socket.read(2).unpack1("n") if length == 126
    length = socket.read(8).unpack1("Q>") if length == 127
    mask = (second & 0x80).positive? ? socket.read(4).bytes : nil
    payload = length.positive? ? socket.read(length) : ""
    payload = payload.bytes.each_with_index.map { |b, i| b ^ mask[i % 4] }.pack("C*") if mask
    payload.force_encoding("UTF-8")
  end

  # Server frames are unmasked per RFC 6455.
  def send_text(socket, data)
    payload = data.b
    header = [ 0x81 ]
    if payload.bytesize < 126
      header << payload.bytesize
    else
      header << 126 << (payload.bytesize >> 8) << (payload.bytesize & 0xFF)
    end
    socket.write(header.pack("C*") + payload)
  end
end
