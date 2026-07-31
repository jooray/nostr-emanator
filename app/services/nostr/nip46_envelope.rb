# frozen_string_literal: true

require "base64"
require "json"
require "openssl"
require "schnorr"
require "securerandom"

module Nostr
  # The kind-24133 transport shared by every NIP-46 client in the app:
  # EventSignerService (signing posts, reactions, uploads), Nip46Client
  # (login/pairing) and Nip46Rpc (bulk encrypt/decrypt for messaging).
  #
  # Extracted because the event builder, the ECDH shared secret and the NIP-04
  # cipher had each been copy-pasted into two services. The fallback policy in
  # particular has to behave identically everywhere: a fork there is a silent
  # downgrade from authenticated NIP-44 to unauthenticated AES-256-CBC.
  #
  # NIP-04 *encryption* is deliberately absent. Both copies defined it and
  # neither ever called it; we only ever need to *read* payloads from a signer
  # too old to speak NIP-44.
  module Nip46Envelope
    KIND = 24_133

    class << self
      # Wrap `content` (an already-encrypted NIP-44 payload) in a signed
      # kind-24133 event addressed to `recipient_pubkey`.
      def build(content:, recipient_pubkey:, sender_privkey:, sender_pubkey:)
        event = {
          "pubkey" => sender_pubkey,
          "created_at" => Time.now.to_i,
          "kind" => KIND,
          "tags" => [ [ "p", recipient_pubkey ] ],
          "content" => content
        }
        event["id"] = EventValidator.event_id(event)
        event["sig"] = sign(event["id"], sender_privkey)
        event
      end

      # Build a complete JSON-RPC request event for the signer.
      # Returns { event:, request_id: }.
      #
      # `conversation_key:` lets a caller reuse a memoized key. That matters:
      # Nip44.conversation_key is a pure-Ruby secp256k1 scalar multiply costing
      # ~29 ms, and Nip46Rpc issues hundreds of requests against one signer.
      def build_request(method:, params:, recipient_pubkey:, sender_privkey:, sender_pubkey:, conversation_key: nil)
        request_id = SecureRandom.hex(16)
        payload = { "id" => request_id, "method" => method, "params" => params }
        content = encrypt(JSON.generate(payload), recipient_pubkey, sender_privkey, conversation_key: conversation_key)

        {
          event: build(
            content: content,
            recipient_pubkey: recipient_pubkey,
            sender_privkey: sender_privkey,
            sender_pubkey: sender_pubkey
          ),
          request_id: request_id
        }
      end

      def encrypt(plaintext, peer_pubkey, our_privkey, conversation_key: nil)
        Nip44.encrypt(conversation_key || Nip44.conversation_key(our_privkey, peer_pubkey), plaintext)
      end

      # NIP-44 first, falling back to deprecated NIP-04 only when policy allows
      # it (see Nip04Policy — off by default). Returns plaintext, or nil when the
      # payload cannot be read. `context` only labels the log line.
      def decrypt(content, peer_pubkey, our_privkey, context:, conversation_key: nil)
        key = conversation_key || Nip44.conversation_key(our_privkey, peer_pubkey)
        Nip44.decrypt(key, content)
      rescue StandardError => e
        Rails.logger.debug("NIP-44 decryption failed (#{context}): #{e.message}")

        unless Nip04Policy.fallback_allowed?
          Nip04Policy.log_refusal(context)
          return nil
        end

        decrypt_nip04(content, peer_pubkey, our_privkey)
      end

      private

      def sign(event_id, privkey_hex)
        Schnorr.sign([ event_id ].pack("H*"), [ privkey_hex ].pack("H*")).encode.unpack1("H*")
      end

      def decrypt_nip04(encrypted_content, their_pubkey_hex, our_privkey_hex)
        parts = encrypted_content.to_s.split("?iv=")
        return nil unless parts.length == 2

        cipher = OpenSSL::Cipher.new("aes-256-cbc")
        cipher.decrypt
        cipher.iv = Base64.decode64(parts[1])
        cipher.key = compute_shared_secret(their_pubkey_hex, our_privkey_hex)

        decrypted = cipher.update(Base64.decode64(parts[0])) + cipher.final
        (+decrypted).force_encoding("UTF-8")
      rescue OpenSSL::Cipher::CipherError, ArgumentError => e
        Rails.logger.warn("NIP-04 decryption failed: #{e.message}")
        nil
      end

      # Raw ECDH x-coordinate, as NIP-04 specifies (no hashing — one of the
      # reasons NIP-44 replaced it).
      def compute_shared_secret(their_pubkey_hex, our_privkey_hex)
        require "ecdsa"

        their_point = ECDSA::Format::PointOctetString.decode(
          [ "02#{their_pubkey_hex}" ].pack("H*"),
          ECDSA::Group::Secp256k1
        )
        shared_point = their_point.multiply_by_scalar(our_privkey_hex.to_i(16))

        [ shared_point.x.to_s(16).rjust(64, "0") ].pack("H*")
      end
    end
  end
end
