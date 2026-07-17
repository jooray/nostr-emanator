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

        length = second & 0x7f
        length = read_exact(socket, 2, deadline).unpack1("n") if length == 126
        length = read_exact(socket, 8, deadline).unpack1("Q>") if length == 127

        if opcode >= 8
          raise FrameError, "invalid control frame" unless fin && length <= 125
          read_exact(socket, length, deadline) if length.positive?
          return nil if opcode == 8
          next if [ 9, 10 ].include?(opcode)
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

    private_class_method :read_exact
  end
end
