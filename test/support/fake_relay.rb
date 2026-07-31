# frozen_string_literal: true

# A minimal in-process WebSocket relay for tests that need real socket I/O
# against the hand-rolled client in Nostr::WebsocketConnection.
#
# Extracted from relay_round_trip_test.rb so the multiplexed NIP-46 client and
# the NIP-42 AUTH handshake can reuse it. Beyond the original it:
#
#   * accepts more than one connection, so reconnect paths are testable
#   * records every handshake request, so header assertions are possible
#   * records every parsed client message, so tests can assert what reached the
#     wire (and, importantly, what did *not* — e.g. an in-flight cap)
#
# The handler runs via instance_exec with the test case as `self`, so it can call
# send_text and the assertion helpers directly.
module FakeRelay
  # `handler` receives (socket, parsed_message) for each client message.
  # Returns the ws:// URL. Connections are served until teardown.
  #
  # `on_connect` runs right after the upgrade, before any client message. Needed
  # for NIP-42: a relay pushes its AUTH challenge unprompted, and a client that
  # must authenticate before subscribing sends nothing until it arrives — so a
  # purely reactive relay deadlocks against it.
  def with_relay(handshake_response: nil, on_connect: nil, &handler)
    server = TCPServer.new("127.0.0.1", 0)
    port = server.addr[1]

    @relay_mutex ||= Mutex.new
    @relay_messages ||= []
    @relay_handshakes ||= []
    @relay_threads ||= []
    @relay_servers ||= []
    @relay_servers << server

    @relay_threads << Thread.new do
      loop do
        socket = server.accept
        @relay_threads << Thread.new do
          request = handshake(socket, response: handshake_response)
          @relay_mutex.synchronize { @relay_handshakes << request }
          instance_exec(socket, &on_connect) if on_connect
          loop do
            payload = read_client_frame(socket)
            break unless payload
            message = JSON.parse(payload)
            @relay_mutex.synchronize { @relay_messages << message }
            instance_exec(socket, message, &handler) if handler
          end
        rescue StandardError
          nil
        ensure
          socket.close rescue nil
        end
      end
    rescue StandardError
      nil
    end

    "ws://127.0.0.1:#{port}"
  end

  # Every client message the relay has parsed so far, in arrival order.
  def relay_messages
    @relay_mutex ? @relay_mutex.synchronize { @relay_messages.dup } : []
  end

  def relay_messages_of(type)
    relay_messages.select { |m| m[0] == type }
  end

  # Raw HTTP upgrade requests, one per accepted connection.
  def relay_handshakes
    @relay_mutex ? @relay_mutex.synchronize { @relay_handshakes.dup } : []
  end

  # Block until `predicate` holds or `timeout` elapses. Returns whether it held.
  # Relay work happens on other threads, so tests must not assert immediately.
  def wait_until(timeout: 2, interval: 0.02)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    loop do
      return true if yield
      return false if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
      sleep interval
    end
  end

  def teardown
    @relay_threads&.each(&:kill)
    @relay_servers&.each { |s| s.close rescue nil }
    super
  end

  # Returns the raw request so callers can assert on headers. `response:`
  # replaces the 101, which is how a 403 (relay refusing the handshake) is
  # simulated.
  def handshake(socket, response: nil)
    request = +""
    request << socket.readpartial(1024) until request.include?("\r\n\r\n")

    if response
      socket.write(response)
      return request
    end

    key = request[/Sec-WebSocket-Key: (.+)\r\n/, 1]
    accept = Base64.strict_encode64(Digest::SHA1.digest(key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"))
    socket.write([
      "HTTP/1.1 101 Switching Protocols",
      "Upgrade: websocket",
      "Connection: Upgrade",
      "Sec-WebSocket-Accept: #{accept}",
      "", ""
    ].join("\r\n"))
    request
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
