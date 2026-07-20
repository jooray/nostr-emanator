# frozen_string_literal: true

require "base64"
require "digest"
require "openssl"
require "socket"

module Nostr
  module WebsocketConnection
    MAX_UPGRADE_SIZE = 16.kilobytes
    CONNECT_TIMEOUT = 5.seconds

    class ConnectionError < StandardError; end

    # H4: every relay socket in the app is opened here, so this is the one place
    # that has to refuse relay URLs coming from unverified NIP-65 lists or user
    # settings (private/loopback/metadata addresses, plaintext ws:// in
    # production). Callers already treat nil as "relay unreachable".
    def self.open(uri, deadline:)
      begin
        Security::UrlGuard.validate_relay!(uri.to_s)
      rescue Security::UrlGuard::UnsafeUrlError => e
        Rails.logger.warn("Refusing to connect to relay #{uri}: #{e.message}")
        return nil
      end

      remaining = remaining_time(deadline)
      tcp_socket = Socket.tcp(uri.host, uri.port, connect_timeout: [ CONNECT_TIMEOUT, remaining ].min)
      tcp_socket.setsockopt(Socket::IPPROTO_TCP, Socket::TCP_NODELAY, 1)

      socket = uri.scheme == "wss" ? connect_tls(tcp_socket, uri.host, deadline) : tcp_socket
      key = Base64.strict_encode64(SecureRandom.random_bytes(16))
      request = [
        "GET #{uri.request_uri} HTTP/1.1",
        "Host: #{uri.host}",
        "Upgrade: websocket",
        "Connection: Upgrade",
        "Sec-WebSocket-Key: #{key}",
        "Sec-WebSocket-Version: 13",
        "",
        ""
      ].join("\r\n")

      write_all(socket, request, deadline)
      response = read_upgrade(socket, deadline: deadline)
      validate_upgrade!(response, key)
      socket
    rescue ConnectionError, IOError, SystemCallError, OpenSSL::SSL::SSLError, SocketError
      socket&.close
      tcp_socket&.close unless tcp_socket&.closed?
      nil
    end

    def self.read_upgrade(socket, deadline:, max_size: MAX_UPGRADE_SIZE)
      read_until(socket, "\r\n\r\n".b, deadline, max_size).force_encoding("UTF-8")
    end

    def self.connect_tls(tcp_socket, host, deadline)
      context = OpenSSL::SSL::SSLContext.new
      context.set_params
      socket = OpenSSL::SSL::SSLSocket.new(tcp_socket, context)
      socket.hostname = host
      socket.sync_close = true

      loop do
        result = socket.connect_nonblock(exception: false)
        return socket if result == socket
        wait_for_io(socket, result, deadline)
      end
    end

    # Encode a text payload as a masked client->server WebSocket frame.
    # Every relay client in the app frames through here (RFC 6455 requires the
    # mask to be unpredictable, hence SecureRandom rather than rand).
    def self.frame_text(data)
      frame(0x1, data)
    end

    # Build any masked client frame (0x1 text, 0xA pong, …).
    def self.frame(opcode, data)
      payload = data.to_s.b
      length = payload.bytesize
      header = [ 0x80 | opcode ]

      if length < 126
        header << (0x80 | length)
      elsif length < 65_536
        header << (0x80 | 126) << (length >> 8) << (length & 0xFF)
      else
        header << (0x80 | 127)
        8.times { |i| header << ((length >> (56 - i * 8)) & 0xFF) }
      end

      mask = SecureRandom.random_bytes(4).bytes
      header.concat(mask)
      masked = payload.bytes.each_with_index.map { |b, i| b ^ mask[i % 4] }
      (header + masked).pack("C*")
    end

    # Frame and write a text message, honouring the deadline (a blocking
    # socket.write against a stalled relay could otherwise hang a worker).
    def self.send_text(socket, data, deadline)
      write_all(socket, frame_text(data), deadline)
    end

    # Answer a server ping (opcode 0x9) with a pong carrying the same payload.
    def self.send_pong(socket, payload, deadline)
      write_all(socket, frame(0xA, payload), deadline)
    end

    # Seconds to hand IO.select: clamped to [0, cap] so a deadline that has just
    # elapsed can never produce a negative timeout (IO.select raises on those).
    def self.select_timeout(deadline, cap = 1)
      [ deadline.to_f - Time.current.to_f, cap.to_f ].min.clamp(0.0, cap.to_f)
    end

    def self.write_all(socket, content, deadline)
      offset = 0
      while offset < content.bytesize
        result = socket.write_nonblock(content.byteslice(offset..), exception: false)
        if result.is_a?(Integer)
          offset += result
        else
          wait_for_io(socket, result, deadline)
        end
      end
    end

    # --- Buffered reader -----------------------------------------------------
    #
    # Ruby 4.0 + OpenSSL 3 break SMALL non-blocking SSL reads: read_nonblock(1)
    # or read_nonblock(2) can return :wait_readable (or "") forever even when a
    # full TLS record of data is sitting decrypted and ready. Large reads work
    # fine. So we never issue small socket reads: refill a per-socket buffer with
    # a big read_nonblock and hand out exact slices from it. This is the single
    # I/O primitive behind BOTH the upgrade handshake and WebsocketFrameReader,
    # so it fixes every relay read path (login, signing, publishing, fetching).
    READ_CHUNK = 64 * 1024

    def self.read_buffer(socket)
      socket.instance_variable_get(:@__ws_read_buffer) ||
        socket.instance_variable_set(:@__ws_read_buffer, +"".b)
    end

    # True if bytes are already available without touching the network (buffered
    # here or pending in the OpenSSL read buffer, which IO.select can't see).
    def self.readable_now?(socket)
      return true if read_buffer(socket).bytesize.positive?
      socket.respond_to?(:pending) && socket.pending.to_i.positive?
    end

    # Read exactly `length` bytes, blocking (up to deadline) as needed.
    def self.read_exact(socket, length, deadline)
      buf = read_buffer(socket)
      fill_buffer(socket, deadline) while buf.bytesize < length
      buf.slice!(0, length)
    end

    # Read through the first occurrence of `terminator`, returning everything up
    # to and including it; any trailing bytes stay buffered for the next read.
    def self.read_until(socket, terminator, deadline, max_size)
      buf = read_buffer(socket)
      until (idx = buf.index(terminator))
        raise ConnectionError, "WebSocket upgrade headers too large" if buf.bytesize >= max_size
        fill_buffer(socket, deadline)
      end
      buf.slice!(0, idx + terminator.bytesize)
    end

    # Pull one large chunk into the buffer, or raise on EOF / deadline. Tolerates
    # every would-block shape Ruby 4.0 surfaces (:wait_readable, :wait_writable,
    # and the bare "" empty string).
    def self.fill_buffer(socket, deadline)
      loop do
        chunk = socket.read_nonblock(READ_CHUNK, exception: false)
        case chunk
        when String
          return read_buffer(socket) << chunk unless chunk.empty?
          wait_for_io(socket, :wait_readable, deadline) # "" => would-block
        when :wait_readable, :wait_writable
          wait_for_io(socket, chunk, deadline)
        when nil
          raise ConnectionError, "connection closed"
        else
          wait_for_io(socket, :wait_readable, deadline)
        end
      end
    end

    def self.wait_for_io(socket, result, deadline)
      remaining = remaining_time(deadline)
      ready = case result
      when :wait_readable then IO.select([ socket ], nil, nil, remaining)
      when :wait_writable then IO.select(nil, [ socket ], nil, remaining)
      else
        # Ruby 4.0 / some OpenSSL builds surface a would-block from
        # {connect,read,write}_nonblock(exception: false) as "" (empty string)
        # instead of a :wait_* symbol. We don't know whether the op wants read
        # or write (a TLS handshake needs either), so wait until the socket is
        # ready for either, then retry. Raising here instead silently killed
        # every relay connection under Ruby 4.0.
        IO.select([ socket ], [ socket ], nil, remaining)
      end
      raise ConnectionError, "WebSocket connection deadline exceeded" unless ready
    end

    def self.remaining_time(deadline)
      remaining = deadline - Time.current
      raise ConnectionError, "WebSocket connection deadline exceeded" unless remaining.positive?
      remaining
    end

    def self.validate_upgrade!(response, key)
      lines = response.split("\r\n")
      raise ConnectionError, "WebSocket upgrade rejected" unless lines.first&.match?(/\AHTTP\/1\.[01] 101\b/)

      headers = lines.drop(1).filter_map do |line|
        name, value = line.split(":", 2)
        [ name.downcase, value.strip ] if value
      end.to_h
      expected = Base64.strict_encode64(Digest::SHA1.digest(key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"))
      raise ConnectionError, "invalid WebSocket upgrade response" unless headers["upgrade"]&.casecmp?("websocket")
      connection_tokens = headers["connection"].to_s.split(",").map { |value| value.strip.downcase }
      raise ConnectionError, "invalid WebSocket upgrade response" unless connection_tokens.include?("upgrade")
      raise ConnectionError, "invalid WebSocket upgrade response" unless headers["sec-websocket-accept"] == expected
    end

    # read_exact / read_until / readable_now? are public: WebsocketFrameReader and
    # the relay read loops call them directly.
    private_class_method :connect_tls, :read_buffer, :fill_buffer, :wait_for_io, :remaining_time, :validate_upgrade!
  end
end
