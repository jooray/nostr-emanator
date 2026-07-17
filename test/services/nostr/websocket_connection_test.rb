# frozen_string_literal: true

require_relative "../../test_helper"

class NostrWebsocketConnectionTest < ActiveSupport::TestCase
  def test_upgrade_read_honors_deadline
    reader, writer = Socket.pair(:UNIX, :STREAM, 0)

    error = assert_raises(Nostr::WebsocketConnection::ConnectionError) do
      Nostr::WebsocketConnection.read_upgrade(reader, deadline: 0.01.seconds.from_now)
    end
    assert_match(/deadline/, error.message)
  ensure
    reader&.close
    writer&.close
  end

  def test_upgrade_read_rejects_oversized_headers
    reader, writer = Socket.pair(:UNIX, :STREAM, 0)
    writer.write("a" * 32)

    error = assert_raises(Nostr::WebsocketConnection::ConnectionError) do
      Nostr::WebsocketConnection.read_upgrade(reader, deadline: 1.second.from_now, max_size: 16)
    end
    assert_match(/too large/, error.message)
  ensure
    reader&.close
    writer&.close
  end
end
