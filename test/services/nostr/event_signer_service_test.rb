# frozen_string_literal: true

require_relative "../../test_helper"

class NostrEventSignerServiceTest < Minitest::Test
  include NostrTestHelper

  def test_returned_signature_must_match_the_requested_event
    pubkey, privkey = keypair
    service = Nostr::EventSignerService.new
    unsigned = service.build_unsigned_event(content: "original", kind: 1, pubkey: pubkey, created_at: Time.now)
    signed = signed_event(
      privkey: privkey,
      pubkey: pubkey,
      kind: unsigned["kind"],
      content: unsigned["content"],
      tags: unsigned["tags"],
      created_at: unsigned["created_at"]
    )

    assert service.send(:valid_signed_event?, signed, unsigned, pubkey)

    altered = signed_event(
      privkey: privkey,
      pubkey: pubkey,
      kind: 1,
      content: "altered",
      tags: [],
      created_at: unsigned["created_at"]
    )
    refute service.send(:valid_signed_event?, altered, unsigned, pubkey)
  end

  def test_raw_reader_rejects_oversized_frames
    reader, writer = Socket.pair(:UNIX, :STREAM, 0)
    writer.write([0x81, 127, Nostr::WebsocketFrameReader::MAX_FRAME_SIZE + 1].pack("CCQ>"))

    assert_nil Nostr::EventSignerService.new.send(:read_websocket_frame, reader, deadline: 1.second.from_now)
  ensure
    reader&.close
    writer&.close
  end
end
