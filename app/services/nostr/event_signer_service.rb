# frozen_string_literal: true

require "json"
require "digest"

module Nostr
  class EventSignerService
    SIGN_TIMEOUT = 120

    def initialize
      @config = Rails.application.config_for(:emanator)
    end

    # Build an unsigned Nostr event
    def build_unsigned_event(content:, kind:, pubkey:, created_at:, tags: [])
      event = {
        "pubkey" => pubkey,
        "created_at" => created_at.to_i,
        "kind" => kind,
        "tags" => tags,
        "content" => content
      }

      # Compute event ID per NIP-01
      serialized = [
        0,
        event["pubkey"],
        event["created_at"],
        event["kind"],
        event["tags"],
        event["content"]
      ]

      event["id"] = Digest::SHA256.hexdigest(JSON.generate(serialized))
      event
    end

    # Build unsigned reply event with NIP-10 tags
    def build_unsigned_reply(content:, pubkey:, created_at:,
                             parent_event_id:, parent_author_pubkey:,
                             root_event_id: nil, relay_hint: "")
      tags = []

      if root_event_id && root_event_id != parent_event_id
        # Threaded reply: root + reply markers
        tags << ["e", root_event_id, relay_hint, "root"]
        tags << ["e", parent_event_id, relay_hint, "reply"]
      else
        # Direct reply to root post
        tags << ["e", parent_event_id, relay_hint, "root"]
      end

      tags << ["p", parent_author_pubkey]

      build_unsigned_event(
        content: content,
        kind: 1,
        pubkey: pubkey,
        created_at: created_at,
        tags: tags
      )
    end

    # Build unsigned repost event (kind 6)
    def build_unsigned_repost(original_event:, pubkey:, created_at:)
      tags = [
        ["e", original_event["id"], ""],
        ["p", original_event["pubkey"]]
      ]

      build_unsigned_event(
        content: JSON.generate(original_event),
        kind: 6,
        pubkey: pubkey,
        created_at: created_at,
        tags: tags
      )
    end

    # Request signature via NIP-46 remote signer
    # Sends to all configured auth relays in parallel, returns first valid response
    def request_signature(account, unsigned_event)
      return nil unless account.signer_pubkey.present? && account.app_privkey.present?

      relay_urls = signing_relays

      # Build the sign_event request and NIP-46 event once (shared across relays)
      request_id = SecureRandom.hex(16)
      nip46_request = {
        "id" => request_id,
        "method" => "sign_event",
        "params" => [JSON.generate(unsigned_event)]
      }
      encrypted = Nip44.encrypt(
        Nip44.conversation_key(account.app_privkey, account.signer_pubkey),
        JSON.generate(nip46_request)
      )
      sign_request_event = build_and_sign_nip46_event(
        content: encrypted,
        recipient_pubkey: account.signer_pubkey,
        sender_privkey: account.app_privkey,
        sender_pubkey: account.app_pubkey
      )

      Rails.logger.info("NIP-46: Sending sign_event request #{request_id} to #{relay_urls.join(', ')} for account #{account.npub}")

      # Send to all relays in parallel, return first valid response
      result = nil
      deadline = Time.now + SIGN_TIMEOUT
      threads = relay_urls.map do |relay_url|
        Thread.new { sign_on_relay(relay_url, account, sign_request_event, request_id, unsigned_event, deadline) }
      end

      loop do
        threads.each do |t|
          next if t.alive?
          value = t.value rescue nil
          if value
            result = value
            break
          end
        end
        break if result
        break if threads.all? { |t| !t.alive? }
        break if Time.now >= deadline
        sleep 0.2
      end

      threads.each { |t| t.kill if t.alive? }

      unless result
        Rails.logger.warn("NIP-46: Signing request #{request_id} timed out after #{SIGN_TIMEOUT}s on all relays")
      end

      result
    rescue => e
      Rails.logger.error("NIP-46 signing error: #{e.class} - #{e.message}")
      nil
    end

    private

    def sign_on_relay(relay_url, account, sign_request_event, request_id, unsigned_event, deadline)
      uri = URI.parse(relay_url)
      backoff = 1

      while Time.now < deadline
        socket = create_websocket(uri, deadline: deadline)
        unless socket
          sleep [backoff, [deadline - Time.now, 0].max].min
          backoff = [backoff * 2, 10].min
          next
        end

        # Subscribe before publishing so fast responses cannot be missed.
        sub_id = "sign-#{SecureRandom.hex(4)}"
        req = ["REQ", sub_id, {
          "kinds" => [24133],
          "#p" => [account.app_pubkey],
          "authors" => [account.signer_pubkey],
          "since" => Time.now.to_i - 5
        }]
        socket.write(frame_text(req.to_json))

        socket.write(frame_text(["EVENT", sign_request_event].to_json))

        while Time.now < deadline
          ready = WebsocketConnection.readable_now?(socket) || IO.select([socket], nil, nil, [1, deadline - Time.now].min)
          next unless ready

          data = read_websocket_frame(socket, deadline: deadline)
          break unless data

          begin
            parsed = JSON.parse(data)
            case parsed[0]
            when "OK"
              accepted = parsed[2]
              Rails.logger.info("NIP-46: Relay #{relay_url} #{accepted ? 'accepted' : 'REJECTED'} sign_event#{accepted ? '' : ": #{parsed[3]}"}")
              unless accepted
                close_socket(socket, sub_id)
                return nil
              end
            when "EVENT"
              response_event = parsed[2]
              next unless EventValidator.valid?(response_event, kind: 24_133, author: account.signer_pubkey, recipient: account.app_pubkey)
              response_content = decrypt_nip44_or_nip04(response_event["content"], account.signer_pubkey, account.app_privkey)
              unless response_content
                Rails.logger.warn("NIP-46: Failed to decrypt response on #{relay_url}")
                next
              end
              response = JSON.parse(response_content)
              Rails.logger.info("NIP-46: Decrypted response on #{relay_url}: id=#{response["id"]} has_result=#{response["result"].present?} has_error=#{response["error"].present?}")
              next unless response["id"] == request_id

              if response["result"] == "auth_url"
                log_auth_challenge(response["error"], request_id, relay_url)
                next
              end

              if response["error"].present?
                Rails.logger.warn("NIP-46: Signer error for #{request_id}: #{response["error"]}")
                close_socket(socket, sub_id)
                return nil
              end

              if response["result"].present?
                signed_event = JSON.parse(response["result"])
                unless valid_signed_event?(signed_event, unsigned_event, account.pubkey_hex)
                  Rails.logger.warn("NIP-46: Signer returned an invalid or altered event for #{request_id}")
                  next
                end
                Rails.logger.info("NIP-46: Received signature for #{request_id} via #{relay_url}")
                close_socket(socket, sub_id)
                return signed_event
              end
            when "NOTICE"
              Rails.logger.info("NIP-46: Relay #{relay_url} notice: #{parsed[1]}")
            end
          rescue JSON::ParserError => e
            Rails.logger.warn("NIP-46: JSON parse error on #{relay_url}: #{e.message}")
          end
        end

        close_socket(socket, sub_id)
        sleep [backoff, [deadline - Time.now, 0].max].min
        backoff = [backoff * 2, 10].min
      end

      nil
    rescue => e
      Rails.logger.error("NIP-46 signing error on #{relay_url}: #{e.class} - #{e.message}")
      nil
    end

    def decrypt_nip44_or_nip04(content, pubkey, privkey)
      Nip44.decrypt(Nip44.conversation_key(privkey, pubkey), content)
    rescue StandardError
      decrypt_nip04(content, pubkey, privkey)
    end

    def valid_signed_event?(signed_event, unsigned_event, account_pubkey)
      return false unless EventValidator.valid?(signed_event, author: account_pubkey)

      %w[pubkey created_at kind tags content].all? do |field|
        signed_event[field] == unsigned_event[field]
      end
    end

    def log_auth_challenge(value, request_id, relay_url)
      uri = URI.parse(value.to_s)
      return unless uri.is_a?(URI::HTTPS) && uri.host.present?

      Rails.logger.warn("NIP-46: request #{request_id} requires authentication at #{uri} (#{relay_url})")
    rescue URI::InvalidURIError
      nil
    end

    def close_socket(socket, sub_id)
      socket.write(frame_text(["CLOSE", sub_id].to_json)) rescue nil
      socket.close rescue nil
    end

    def signing_relays
      @config.dig(:nostr, :auth_relays) ||
        [@config.dig(:nostr, :auth_relay)].compact.presence ||
        ["wss://relay.nsec.app"]
    end

    def encrypt_nip04(plaintext, their_pubkey_hex, our_privkey_hex)
      shared_secret = compute_shared_secret(their_pubkey_hex, our_privkey_hex)

      cipher = OpenSSL::Cipher.new("aes-256-cbc")
      cipher.encrypt
      iv = cipher.random_iv
      cipher.key = shared_secret

      encrypted = cipher.update(plaintext) + cipher.final
      "#{Base64.strict_encode64(encrypted)}?iv=#{Base64.strict_encode64(iv)}"
    end

    def decrypt_nip04(encrypted_content, their_pubkey_hex, our_privkey_hex)
      parts = encrypted_content.split("?iv=")
      return nil unless parts.length == 2

      ciphertext = Base64.decode64(parts[0])
      iv = Base64.decode64(parts[1])
      shared_secret = compute_shared_secret(their_pubkey_hex, our_privkey_hex)

      cipher = OpenSSL::Cipher.new("aes-256-cbc")
      cipher.decrypt
      cipher.iv = iv
      cipher.key = shared_secret

      decrypted = cipher.update(ciphertext) + cipher.final
      (+decrypted).force_encoding("UTF-8")
    rescue OpenSSL::Cipher::CipherError
      nil
    end

    def compute_shared_secret(their_pubkey_hex, our_privkey_hex)
      require "ecdsa"

      group = ECDSA::Group::Secp256k1
      their_point = ECDSA::Format::PointOctetString.decode(
        ["02#{their_pubkey_hex}"].pack("H*"),
        group
      )

      our_private_key = our_privkey_hex.to_i(16)
      shared_point = their_point.multiply_by_scalar(our_private_key)

      [shared_point.x.to_s(16).rjust(64, "0")].pack("H*")
    end

    def build_and_sign_nip46_event(content:, recipient_pubkey:, sender_privkey:, sender_pubkey:)
      # Build the event structure
      event = {
        "pubkey" => sender_pubkey,
        "created_at" => Time.now.to_i,
        "kind" => 24133,
        "tags" => [["p", recipient_pubkey]],
        "content" => content
      }

      event["id"] = EventValidator.event_id(event)

      # Sign with Schnorr (BIP-340) as required by Nostr
      require "schnorr"
      message = [event["id"]].pack("H*")
      privkey_bytes = [sender_privkey].pack("H*")
      signature = Schnorr.sign(message, privkey_bytes)
      event["sig"] = signature.encode.unpack1("H*")

      event
    end

    # WebSocket helpers (same pattern as other services)
    def create_websocket(uri, deadline:)
      WebsocketConnection.open(uri, deadline: deadline)
    end

    def frame_text(data)
      bytes = data.bytes
      frame = [0x81]
      if bytes.length < 126
        frame << (0x80 | bytes.length)
      elsif bytes.length < 65536
        frame << (0x80 | 126) << (bytes.length >> 8) << (bytes.length & 0xFF)
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
