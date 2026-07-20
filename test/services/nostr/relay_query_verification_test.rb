# frozen_string_literal: true

require_relative "../../test_helper"

# H3: events served by a relay are cryptographically verified before any caller
# sees them, and H4: a relay URL pointing at a non-public host is never dialled.
class NostrRelayQueryVerificationTest < ActiveSupport::TestCase
  include NostrTestHelper

  def test_events_with_a_broken_signature_are_dropped
    pubkey, privkey = keypair
    good = signed_event(privkey: privkey, pubkey: pubkey, kind: 0, content: "{}")
    tampered = signed_event(privkey: privkey, pubkey: pubkey, kind: 0, content: "{}")
    tampered["content"] = "{\"name\":\"evil\"}" # id/sig no longer match the content

    url = with_relay do |socket, message|
      next unless message[0] == "REQ"
      sub_id = message[1]
      send_text(socket, [ "EVENT", sub_id, tampered ].to_json)
      send_text(socket, [ "EVENT", sub_id, good ].to_json)
      send_text(socket, [ "EOSE", sub_id ].to_json)
    end

    events = Nostr::RelayQuery.run(url, { "kinds" => [ 0 ], "authors" => [ pubkey ] }, timeout: 5)

    assert_equal [ good["id"] ], events.map { |e| e["id"] },
      "only the correctly signed event may survive"
  end

  def test_events_for_another_author_or_kind_are_dropped
    _asked_for, _priv = keypair
    other_pubkey, other_privkey = keypair
    impostor = signed_event(privkey: other_privkey, pubkey: other_pubkey, kind: 0, content: "{}")
    wrong_kind = signed_event(privkey: other_privkey, pubkey: other_pubkey, kind: 1, content: "hi")

    url = with_relay do |socket, message|
      next unless message[0] == "REQ"
      sub_id = message[1]
      send_text(socket, [ "EVENT", sub_id, impostor ].to_json)
      send_text(socket, [ "EVENT", sub_id, wrong_kind ].to_json)
      send_text(socket, [ "EOSE", sub_id ].to_json)
    end

    asked_pubkey, = keypair
    events = Nostr::RelayQuery.run(
      url,
      { "kinds" => [ 0 ], "authors" => [ asked_pubkey ] },
      timeout: 5,
      kind: 0,
      author: asked_pubkey
    )

    assert_empty events, "a relay may not answer with events we did not ask for"
  end

  def test_unsafe_relay_urls_are_refused_without_connecting
    server = TCPServer.new("127.0.0.1", 0)
    port = server.addr[1]
    connected = false
    thread = Thread.new { server.accept; connected = true }

    with_guard_enabled do
      assert_nil Nostr::RelayQuery.run("ws://127.0.0.1:#{port}", { "kinds" => [ 0 ] }, timeout: 2)
    end

    refute connected, "the guard must refuse the URL before a socket is opened"
  ensure
    thread&.kill
    server&.close
  end

  private

  def with_guard_enabled
    previous = Rails.application.config.x.allow_private_network_urls
    Rails.application.config.x.allow_private_network_urls = false
    yield
  ensure
    Rails.application.config.x.allow_private_network_urls = previous
  end

  # Minimal in-process relay (same shape as relay_round_trip_test).
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
        instance_exec(socket, JSON.parse(payload), &handler)
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
