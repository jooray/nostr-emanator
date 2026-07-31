# frozen_string_literal: true

require "json"
require "base64"
require "openssl"
require "socket"
require "digest"

module Nostr
  # NIP-46 protocol helpers: decrypt signer-sent events, validate connect
  # responses, build and sign outgoing request events, and WebSocket I/O.
  # The per-relay listener loop lives in Nip46Supervisor.
  class Nip46Client
    def initialize(auth_session)
      @auth_session = auth_session
      @relay_urls = auth_session.relay_urls
      @temp_pubkey = auth_session.temp_pubkey
      @temp_privkey = auth_session.temp_privkey
      @secret = auth_session.secret
    end

    # Decrypt and parse a kind-24133 event from the signer.
    # Returns { signer_pubkey:, message: } on success, nil on decrypt/parse failure.
    def decrypt_signer_event(event_data)
      unless EventValidator.valid?(event_data, kind: 24_133, recipient: @temp_pubkey)
        Rails.logger.warn("NIP-46: rejected invalid or misaddressed signer event")
        return nil
      end

      unless fresh?(event_data)
        Rails.logger.warn("NIP-46: rejected stale signer event (created_at #{event_data["created_at"].inspect})")
        return nil
      end

      signer_pubkey = event_data["pubkey"]
      encrypted_content = event_data["content"]

      decrypted = Nip46Envelope.decrypt(
        encrypted_content, signer_pubkey, @temp_privkey, context: "NIP-46 handshake"
      )

      unless decrypted
        Rails.logger.warn("NIP-46: decrypt failed for event from #{signer_pubkey}")
        return nil
      end

      message = JSON.parse(decrypted)
      { signer_pubkey: signer_pubkey, message: message }
    rescue JSON::ParserError => e
      Rails.logger.warn("NIP-46: decrypted payload is not JSON: #{e.message}")
      nil
    end

    # Validate that a decrypted message is a legitimate connect response for this session.
    def valid_connect_response?(message)
      return false unless message.is_a?(Hash)

      if message["result"]
        return true if message["result"] == @secret
        # .inspect so a newline in relay-supplied text cannot forge log lines.
        Rails.logger.warn("NIP-46: connect result #{message["result"].inspect} does not match secret")
        return false
      end

      false
    end

    # Build an encrypted + signed kind-24133 request event for the signer.
    # Returns { event:, request_id: }.
    def build_request_event(signer_pubkey, method, params = [])
      Nip46Envelope.build_request(
        method: method,
        params: params,
        recipient_pubkey: signer_pubkey,
        sender_privkey: @temp_privkey,
        sender_pubkey: @temp_pubkey
      )
    end

    # Defense-in-depth freshness check (NIP-46 recommends one). Cross-session
    # replay is already impossible — every session has its own random key,
    # secret and request ids — so the window is deliberately wide: some signers
    # tweak `created_at` for privacy, and rejecting those would break logins for
    # no real gain.
    MAX_EVENT_AGE = 24 * 60 * 60
    MAX_EVENT_SKEW = 15 * 60

    def fresh?(event_data)
      created_at = event_data["created_at"]
      return false unless created_at.is_a?(Integer)

      age = Time.now.to_i - created_at
      age <= MAX_EVENT_AGE && age >= -MAX_EVENT_SKEW
    end

    def create_websocket(uri, deadline:)
      WebsocketConnection.open(uri, deadline: deadline)
    end

    def frame_text(data)
      WebsocketConnection.frame_text(data)
    end

    def read_websocket_frame(socket, deadline:)
      WebsocketFrameReader.read(socket, deadline: deadline)
    rescue WebsocketFrameReader::FrameError
      nil
    end
  end
end
