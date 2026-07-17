# frozen_string_literal: true

require "json"
require "base64"
require "openssl"
require "socket"
require "digest"

module Nostr
  # NIP-46 protocol helpers: decrypt signer-sent events, validate connect
  # responses, build and sign outgoing request events, and WebSocket I/O.
  # The per-relay listener loop lives in Nip46Listener.
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

      signer_pubkey = event_data["pubkey"]
      encrypted_content = event_data["content"]

      decrypted = try_decrypt_nip44(encrypted_content, signer_pubkey)
      decrypted ||= decrypt_nip04(encrypted_content, signer_pubkey)

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
        Rails.logger.warn("NIP-46: connect result '#{message["result"]}' does not match secret")
        return false
      end

      false
    end

    # Build an encrypted + signed kind-24133 request event for the signer.
    # Returns { event:, request_id: }.
    def build_request_event(signer_pubkey, method, params = [])
      request_id = SecureRandom.hex(16)
      payload = { "id" => request_id, "method" => method, "params" => params }
      encrypted = Nip44.encrypt(Nip44.conversation_key(@temp_privkey, signer_pubkey), JSON.generate(payload))
      event = build_and_sign_event(encrypted, signer_pubkey)
      { event: event, request_id: request_id }
    end

    def try_decrypt_nip44(encrypted_content, signer_pubkey)
      conv_key = Nip44.conversation_key(@temp_privkey, signer_pubkey)
      Nip44.decrypt(conv_key, encrypted_content)
    rescue => e
      Rails.logger.debug("NIP-44 decryption failed: #{e.message}")
      nil
    end

    def decrypt_nip04(encrypted_content, signer_pubkey)
      parts = encrypted_content.split("?iv=")
      return nil unless parts.length == 2

      ciphertext = Base64.decode64(parts[0])
      iv = Base64.decode64(parts[1])
      shared_secret = compute_shared_secret(signer_pubkey)

      cipher = OpenSSL::Cipher.new("aes-256-cbc")
      cipher.decrypt
      cipher.iv = iv
      cipher.key = shared_secret

      decrypted = cipher.update(ciphertext) + cipher.final
      (+decrypted).force_encoding("UTF-8")
    rescue OpenSSL::Cipher::CipherError, ArgumentError => e
      Rails.logger.error("NIP-04 decryption failed: #{e.message}")
      nil
    end

    def encrypt_nip04(plaintext, recipient_pubkey)
      shared_secret = compute_shared_secret(recipient_pubkey)

      cipher = OpenSSL::Cipher.new("aes-256-cbc")
      cipher.encrypt
      iv = cipher.random_iv
      cipher.key = shared_secret

      encrypted = cipher.update(plaintext) + cipher.final
      "#{Base64.strict_encode64(encrypted)}?iv=#{Base64.strict_encode64(iv)}"
    end

    def compute_shared_secret(their_pubkey_hex)
      require "ecdsa"

      group = ECDSA::Group::Secp256k1
      their_point = ECDSA::Format::PointOctetString.decode(
        ["02#{their_pubkey_hex}"].pack("H*"),
        group
      )

      our_private_key = @temp_privkey.to_i(16)
      shared_point = their_point.multiply_by_scalar(our_private_key)

      [shared_point.x.to_s(16).rjust(64, "0")].pack("H*")
    end

    def build_and_sign_event(content, recipient_pubkey)
      event = {
        "pubkey" => @temp_pubkey,
        "created_at" => Time.now.to_i,
        "kind" => 24133,
        "tags" => [["p", recipient_pubkey]],
        "content" => content
      }

      event["id"] = EventValidator.event_id(event)

      require "schnorr"
      message = [event["id"]].pack("H*")
      privkey_bytes = [@temp_privkey].pack("H*")
      signature = Schnorr.sign(message, privkey_bytes)
      event["sig"] = signature.encode.unpack1("H*")

      event
    end

    def create_websocket(uri, deadline:)
      WebsocketConnection.open(uri, deadline: deadline)
    end

    def frame_text(data)
      bytes = data.bytes
      frame = [0x81]

      if bytes.length < 126
        frame << (0x80 | bytes.length)
      elsif bytes.length < 65536
        frame << (0x80 | 126)
        frame << (bytes.length >> 8)
        frame << (bytes.length & 0xFF)
      else
        frame << (0x80 | 127)
        8.times { |i| frame << ((bytes.length >> (56 - i * 8)) & 0xFF) }
      end

      mask = 4.times.map { rand(256) }
      frame.concat(mask)

      bytes.each_with_index { |b, i| frame << (b ^ mask[i % 4]) }

      frame.pack("C*")
    end

    def read_websocket_frame(socket, deadline:)
      WebsocketFrameReader.read(socket, deadline: deadline)
    rescue WebsocketFrameReader::FrameError
      nil
    end
  end
end
