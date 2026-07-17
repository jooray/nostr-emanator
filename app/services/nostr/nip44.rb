# frozen_string_literal: true

require "openssl"
require "base64"

module Nostr
  # NIP-44 v2 encryption and decryption.
  module Nip44
    PROTOCOL_VERSION = 2
    MAX_PLAINTEXT_SIZE = 1.megabyte
    MAX_PAYLOAD_SIZE = 2.megabytes

    class Error < StandardError; end
    class DecryptionError < Error; end

    # Derive conversation key from ECDH shared secret.
    # privkey_hex: our temp private key (hex string)
    # pubkey_hex: their public key (hex string, x-only 32 bytes)
    def self.conversation_key(privkey_hex, pubkey_hex)
      require "ecdsa"

      group = ECDSA::Group::Secp256k1
      our_private_key = privkey_hex.to_i(16)
      raise Error, "invalid private key" unless our_private_key.between?(1, group.order - 1)
      raise Error, "invalid public key" unless pubkey_hex.match?(/\A[0-9a-f]{64}\z/i)

      their_point = ECDSA::Format::PointOctetString.decode_from_x([pubkey_hex].pack("H*"), group)
      shared_point = their_point.multiply_by_scalar(our_private_key)
      shared_x = [shared_point.x.to_s(16).rjust(64, "0")].pack("H*")

      # HKDF-Extract: PRK = HMAC-SHA256(salt, IKM)
      salt = "nip44-v2"
      OpenSSL::HMAC.digest("SHA256", salt, shared_x)
    end

    def self.encrypt(conv_key, plaintext, nonce: SecureRandom.random_bytes(32))
      raise Error, "invalid conversation key" unless conv_key.bytesize == 32
      raise Error, "invalid nonce" unless nonce.bytesize == 32

      padded = pad(plaintext)
      chacha_key, chacha_nonce, hmac_key = message_keys(conv_key, nonce)
      ciphertext = chacha20(chacha_key, chacha_nonce, padded, encrypt: true)
      mac = OpenSSL::HMAC.digest("SHA256", hmac_key, nonce + ciphertext)
      Base64.strict_encode64([PROTOCOL_VERSION].pack("C") + nonce + ciphertext + mac)
    end

    # Decrypt a NIP-44 v2 payload.
    # conv_key: 32-byte conversation key from conversation_key()
    # base64_payload: base64-encoded encrypted payload
    # Returns decrypted plaintext string.
    def self.decrypt(conv_key, base64_payload)
      raise DecryptionError, "unsupported encoding" if base64_payload.start_with?("#")
      raise DecryptionError, "invalid payload size" unless base64_payload.bytesize.between?(132, MAX_PAYLOAD_SIZE)

      payload = Base64.strict_decode64(base64_payload)
      raise DecryptionError, "payload too short" if payload.bytesize < 99 # 1 + 32 + 32 + 2 + 32

      version = payload.getbyte(0)
      raise DecryptionError, "unsupported version: #{version}" unless version == PROTOCOL_VERSION

      nonce = payload.byteslice(1, 32)
      mac = payload.byteslice(-32, 32)
      ciphertext = payload.byteslice(33, payload.bytesize - 65) # between nonce and mac

      # HKDF-Expand to derive chacha_key (32) + chacha_nonce (12) + hmac_key (32) = 76 bytes
      chacha_key, chacha_nonce, hmac_key = message_keys(conv_key, nonce)

      # Verify HMAC (constant-time comparison)
      expected_mac = OpenSSL::HMAC.digest("SHA256", hmac_key, nonce + ciphertext)
      unless OpenSSL.fixed_length_secure_compare(mac, expected_mac)
        raise DecryptionError, "HMAC verification failed"
      end

      # ChaCha20 decrypt
      unpad(chacha20(chacha_key, chacha_nonce, ciphertext, encrypt: false))
    rescue ArgumentError => e
      raise DecryptionError, e.message
    end

    def self.message_keys(conv_key, nonce)
      keys = hkdf_expand(conv_key, nonce, 76)
      [keys.byteslice(0, 32), keys.byteslice(32, 12), keys.byteslice(44, 32)]
    end

    def self.chacha20(key, nonce, content, encrypt:)
      cipher = OpenSSL::Cipher.new("chacha20")
      encrypt ? cipher.encrypt : cipher.decrypt
      cipher.key = key
      cipher.iv = "\x00\x00\x00\x00".b + nonce
      cipher.update(content) + cipher.final
    end

    def self.calc_padded_len(length)
      return 32 if length <= 32

      next_power = 1 << length.bit_length
      chunk = next_power <= 256 ? 32 : next_power / 8
      chunk * ((length - 1) / chunk + 1)
    end

    def self.pad(plaintext)
      bytes = plaintext.to_s.encode("UTF-8").b
      length = bytes.bytesize
      raise Error, "invalid plaintext length" unless length.between?(1, MAX_PLAINTEXT_SIZE)

      prefix = length < 65_536 ? [length].pack("n") : [0, length].pack("nN")
      prefix + bytes + ("\0" * (calc_padded_len(length) - length))
    end

    # HKDF-Expand (RFC 5869 Section 2.3)
    def self.hkdf_expand(prk, info, length)
      hash_len = 32 # SHA-256
      n = (length + hash_len - 1) / hash_len
      okm = +""
      t = +""

      (1..n).each do |i|
        t = OpenSSL::HMAC.digest("SHA256", prk, t + info + [i].pack("C"))
        okm << t
      end

      okm.byteslice(0, length)
    end

    # Remove NIP-44 padding: 2-byte BE length prefix + plaintext + zero padding
    def self.unpad(padded)
      raise DecryptionError, "padded data too short" if padded.bytesize < 2

      plaintext_len = padded.byteslice(0, 2).unpack1("n")
      prefix_len = 2
      if plaintext_len.zero?
        raise DecryptionError, "padded data too short" if padded.bytesize < 6
        plaintext_len = padded.byteslice(2, 4).unpack1("N")
        prefix_len = 6
        raise DecryptionError, "invalid extended length" if plaintext_len < 65_536
      end
      raise DecryptionError, "invalid plaintext length" unless plaintext_len.between?(1, MAX_PLAINTEXT_SIZE)
      expected_size = prefix_len + calc_padded_len(plaintext_len)
      raise DecryptionError, "invalid padding length" unless padded.bytesize == expected_size

      plaintext = padded.byteslice(prefix_len, plaintext_len)

      (+plaintext).force_encoding("UTF-8")
    end

    private_class_method :hkdf_expand, :message_keys, :chacha20, :pad, :unpad
  end
end
