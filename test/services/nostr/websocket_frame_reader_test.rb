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
