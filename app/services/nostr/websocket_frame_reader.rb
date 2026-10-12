# frozen_string_literal: true

module Nostr
  module WebsocketFrameReader
    MAX_FRAME_SIZE = 2.megabytes

    class FrameError < StandardError; end

    def self.read(socket, deadline:, max_size: MAX_FRAME_SIZE)
      message = +"".b
      fragmented = false

      loop do
        first, second = read_exact(socket, 2, deadline).bytes
        fin = (first & 0x80) != 0
        raise FrameError, "RSV bits are not supported" unless (first & 0x70).zero?

        opcode = first & 0x0f
        masked = (second & 0x80) != 0
        raise FrameError, "server frames must not be masked" if masked

        # elsif, not a second `if`: a 127-byte payload is encoded with the
        # 16-bit form (126), and the length it yields is 127 — which a second
        # `if` then reads as "64-bit length follows", consuming 8 payload bytes
        # as a bogus length and killing the connection mid-subscription.
        length = second & 0x7f
        if length == 126
          length = read_exact(socket, 2, deadline).unpack1("n")
        elsif length == 127
          length = read_exact(socket, 8, deadline).unpack1("Q>")
        end

        if opcode >= 8
          raise FrameError, "invalid control frame" unless fin && length <= 125
          payload = length.positive? ? read_exact(socket, length, deadline) : +"".b

          # Close frame: the connection is finished, tell the caller.
          return nil if opcode == WebsocketConnection::OPCODE_CLOSE

          # Ping: answer with a pong carrying the same payload, otherwise
          # keepalive-enforcing relays disconnect us.
          if opcode == WebsocketConnection::OPCODE_PING
            send_pong(socket, payload, deadline)
            next
          end

          next if opcode == WebsocketConnection::OPCODE_PONG
          raise FrameError, "unsupported control opcode"
        end

        if opcode == 1
          raise FrameError, "unexpected text frame" if fragmented
          fragmented = !fin
        elsif opcode == 0
          raise FrameError, "unexpected continuation frame" unless fragmented
        else
          raise FrameError, "unsupported data opcode"
        end

        raise FrameError, "frame exceeds maximum size" if length > max_size - message.bytesize
        message << read_exact(socket, length, deadline) if length.positive?
        return message.force_encoding("UTF-8") if fin
      end
    end

    # Delegate to WebsocketConnection's buffered reader: Ruby 4.0 + OpenSSL 3
    # break small non-blocking SSL reads (a 2-byte frame header could hang
    # forever), so all socket reads must go through the big-read/slice buffer.
    def self.read_exact(socket, length, deadline)
      WebsocketConnection.read_exact(socket, length, deadline)
    rescue WebsocketConnection::ConnectionError => e
      raise FrameError, e.message
    rescue EOFError, IOError, SystemCallError => e
      raise FrameError, e.message
    end

    def self.send_pong(socket, payload, deadline)
      WebsocketConnection.send_pong(socket, payload, deadline: deadline)
    rescue WebsocketConnection::ConnectionError => e
      raise FrameError, e.message
    rescue IOError, SystemCallError, OpenSSL::SSL::SSLError => e
      raise FrameError, e.message
    end

    private_class_method :read_exact, :send_pong
  end
end
