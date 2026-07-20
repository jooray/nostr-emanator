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

  # C1: every relay path must verify the server certificate. A self-signed cert
  # (what a MITM would present) has to fail the handshake, not be accepted.
  def test_tls_certificate_is_verified
    server, port, thread = start_self_signed_tls_server

    assert_nil Nostr::WebsocketConnection.open(URI.parse("wss://127.0.0.1:#{port}"), deadline: 5.seconds.from_now)

    # The same guarantee must hold for the services that publish/fetch.
    assert_equal :error,
      Nostr::EventPublisherService.new.send(:publish_to_relay, "wss://127.0.0.1:#{port}", { "id" => "abc" })
    assert_nil Nostr::RelayQuery.run("wss://127.0.0.1:#{port}", { "kinds" => [ 0 ] }, timeout: 2)
  ensure
    server&.close
    thread&.kill
  end

  def test_select_timeout_never_goes_negative
    assert_equal 0.0, Nostr::WebsocketConnection.select_timeout(5.seconds.ago)
    assert_equal 1.0, Nostr::WebsocketConnection.select_timeout(30.seconds.from_now)
    assert_equal 0.5, Nostr::WebsocketConnection.select_timeout(30.seconds.from_now, 0.5)
    assert_operator Nostr::WebsocketConnection.select_timeout(0.2.seconds.from_now), :<=, 0.2
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

  private

  # A TLS server with a self-signed, untrusted certificate — the exact shape of
  # an on-path relay impersonation attempt.
  def start_self_signed_tls_server
    key = OpenSSL::PKey::RSA.new(2048)
    cert = OpenSSL::X509::Certificate.new
    cert.version = 2
    cert.serial = 1
    cert.subject = cert.issuer = OpenSSL::X509::Name.parse("/CN=127.0.0.1")
    cert.public_key = key.public_key
    cert.not_before = Time.now - 60
    cert.not_after = Time.now + 3600
    cert.sign(key, OpenSSL::Digest::SHA256.new)

    context = OpenSSL::SSL::SSLContext.new
    context.cert = cert
    context.key = key

    tcp_server = TCPServer.new("127.0.0.1", 0)
    port = tcp_server.addr[1]
    server = OpenSSL::SSL::SSLServer.new(tcp_server, context)
    thread = Thread.new do
      loop do
        client = server.accept rescue next
        client.close rescue nil
      end
    end

    [ server, port, thread ]
  end
end
