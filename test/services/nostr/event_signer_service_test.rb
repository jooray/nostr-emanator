# frozen_string_literal: true

require_relative "../../test_helper"

class NostrEventSignerServiceTest < Minitest::Test
  include NostrTestHelper

  # The mentions and quotes a user writes only reach anyone if they are also
  # tags on the event we sign.
  def test_a_note_carries_the_tags_its_text_implies
    author = "ef" * 32
    npub = Nostr::KeyConverter.hex_to_npub("11" * 32)
    nevent = Nostr::KeyConverter.hex_to_nevent("ab" * 32, relays: ["wss://nos.lol"], author_pubkey: "cd" * 32)

    event = Nostr::EventSignerService.new.build_unsigned_note(
      content: "ahoj nostr:#{npub}\n\nnostr:#{nevent}",
      pubkey: author,
      created_at: Time.now
    )

    assert_equal 1, event["kind"]
    assert_includes event["tags"], ["q", "ab" * 32, "wss://nos.lol", "cd" * 32]
    assert_includes event["tags"], ["p", "11" * 32]
  end

  # A reply already points at its parent with an `e` tag; restating it as a `q`
  # would claim the reply quotes the thing it answers.
  def test_a_reply_tags_its_body_without_re_quoting_the_thread
    author = "ef" * 32
    parent_id = "ab" * 32
    parent_author = "cd" * 32
    nevent = Nostr::KeyConverter.hex_to_nevent(parent_id, author_pubkey: parent_author)
    npub = Nostr::KeyConverter.hex_to_npub("11" * 32)

    event = Nostr::EventSignerService.new.build_unsigned_reply(
      content: "nostr:#{nevent} a nostr:#{npub}",
      pubkey: author,
      created_at: Time.now,
      parent_event_id: parent_id,
      parent_author_pubkey: parent_author
    )

    assert_empty event["tags"].select { |t| t.first == "q" }
    assert_equal 1, event["tags"].count { |t| t.first == "p" && t[1] == parent_author }
    assert_includes event["tags"], ["p", "11" * 32]
  end

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
