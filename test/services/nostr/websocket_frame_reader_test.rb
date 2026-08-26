# frozen_string_literal: true

require_relative "../../test_helper"

class NostrWebsocketFrameReaderTest < ActiveSupport::TestCase
  def test_reads_fragmented_text_with_exact_partial_reads
    reader, writer = Socket.pair(:UNIX, :STREAM, 0)
    writer.write([0x01, 3].pack("CC") + "hel" + [0x80, 2].pack("CC") + "lo")

    assert_equal "hello", Nostr::WebsocketFrameReader.read(reader, deadline: 1.second.from_now)
  ensure
    reader&.close
    writer&.close
  end

  def test_rejects_oversized_frame_before_reading_payload
    reader, writer = Socket.pair(:UNIX, :STREAM, 0)
    writer.write([0x81, 127, Nostr::WebsocketFrameReader::MAX_FRAME_SIZE + 1].pack("CCQ>"))

    error = assert_raises(Nostr::WebsocketFrameReader::FrameError) do
      Nostr::WebsocketFrameReader.read(reader, deadline: 1.second.from_now)
    end
    assert_match(/maximum size/, error.message)
  ensure
    reader&.close
    writer&.close
  end

  # RFC 6455 encodes a 127-byte payload with the 16-bit form, so the length it
  # yields is 127 — which a second, independent `if length == 127` then reads as
  # "a 64-bit length follows", eating 8 payload bytes as a bogus length.
  def test_reads_a_payload_of_exactly_127_bytes
    payload = "x" * 127
    reader, writer = Socket.pair(:UNIX, :STREAM, 0)
    writer.write([0x81, 126, payload.bytesize].pack("CCn") + payload)

    assert_equal payload, Nostr::WebsocketFrameReader.read(reader, deadline: 1.second.from_now)
  ensure
    reader&.close
    writer&.close
  end

  def test_answers_ping_with_a_pong_carrying_the_same_payload
    reader, writer = Socket.pair(:UNIX, :STREAM, 0)
    writer.write([0x89, 4].pack("CC") + "ping" + [0x81, 2].pack("CC") + "hi")

    assert_equal "hi", Nostr::WebsocketFrameReader.read(reader, deadline: 1.second.from_now)

    header = writer.read(2).bytes
    assert_equal 0x8A, header[0], "expected a FIN pong frame (opcode 0xA)"
    assert_equal 0x80 | 4, header[1], "pong must be masked and carry the ping payload"
    mask = writer.read(4).bytes
    payload = writer.read(4).bytes.each_with_index.map { |b, i| b ^ mask[i % 4] }.pack("C*")
    assert_equal "ping", payload
  ensure
    reader&.close
    writer&.close
  end

  def test_exact_read_honors_deadline
    reader, writer = Socket.pair(:UNIX, :STREAM, 0)

    assert_raises(Nostr::WebsocketFrameReader::FrameError) do
      Nostr::WebsocketFrameReader.read(reader, deadline: 0.01.seconds.from_now)
    end
  ensure
    reader&.close
    writer&.close
  end
end
