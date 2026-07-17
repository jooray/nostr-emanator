# frozen_string_literal: true

require_relative "../../test_helper"

class NostrNip46ClientTest < Minitest::Test
  include NostrTestHelper

  Session = Data.define(:relay_urls, :temp_pubkey, :temp_privkey, :secret)

  def setup
    @client_pubkey, @client_privkey = keypair
    @signer_pubkey, @signer_privkey = keypair
    @secret = "server-secret"
    @client = Nostr::Nip46Client.new(Session.new(["wss://relay.example"], @client_pubkey, @client_privkey, @secret))
  end

  def test_connect_accepts_only_exact_secret_response
    assert @client.valid_connect_response?({ "result" => @secret })
    refute @client.valid_connect_response?({ "result" => "ack" })
    refute @client.valid_connect_response?({ "method" => "connect", "params" => [@secret] })
  end

  def test_decrypts_only_valid_signed_and_addressed_event
    message = JSON.generate("result" => @secret)
    content = Nostr::Nip44.encrypt(Nostr::Nip44.conversation_key(@signer_privkey, @client_pubkey), message)
    event = signed_event(
      privkey: @signer_privkey,
      pubkey: @signer_pubkey,
      kind: 24_133,
      content: content,
      tags: [["p", @client_pubkey]]
    )

    assert_equal({ "result" => @secret }, @client.decrypt_signer_event(event)[:message])

    event["tags"] = [["p", "0" * 64]]
    assert_nil @client.decrypt_signer_event(event)
  end

  def test_raw_reader_rejects_oversized_frames
    reader, writer = Socket.pair(:UNIX, :STREAM, 0)
    writer.write([0x81, 127, Nostr::WebsocketFrameReader::MAX_FRAME_SIZE + 1].pack("CCQ>"))

    assert_nil @client.read_websocket_frame(reader, deadline: 1.second.from_now)
  ensure
    reader&.close
    writer&.close
  end
end
