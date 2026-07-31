# frozen_string_literal: true

require "json"
require "digest"

module Nostr
  class EventSignerService
    SIGN_TIMEOUT = 120

    # I9: signing always uses the relays configured in config/emanator.yml, not
    # the per-account `signer_relay` column. `signer_relay` is only a record of
    # the relay the signer advertised at pairing time (shown in the UI / useful
    # for debugging) — it is deliberately NOT live configuration, since an
    # attacker-supplied pairing URI must not be able to redirect our signing
    # traffic. Don't read it here expecting it to take effect.
    #
    # Public so Nip46Rpc shares one definition of "where the signer listens".
    def self.signing_relays(config = Rails.application.config_for(:emanator))
      config.dig(:nostr, :auth_relays) ||
        [ config.dig(:nostr, :auth_relay) ].compact.presence ||
        [ "wss://relay.nsec.app" ]
    end

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

    # Raised when an id/pubkey handed to a builder is not a NIP-01 32-byte hex
    # value. These come from the browser (the inline reply / interactions UI),
    # so they are checked before they end up inside an event we sign.
    class InvalidReferenceError < ArgumentError; end

    HEX_32 = /\A[0-9a-f]{64}\z/

    # Build unsigned reply event with NIP-10 tags
    def build_unsigned_reply(content:, pubkey:, created_at:,
                             parent_event_id:, parent_author_pubkey:,
                             root_event_id: nil, relay_hint: "")
      # L2: reject anything that is not a 64-char lowercase hex id/pubkey.
      validate_hex32!(parent_event_id, "parent event id")
      validate_hex32!(parent_author_pubkey, "parent author pubkey")
      validate_hex32!(root_event_id, "root event id") if root_event_id.present?
      validate_hex32!(pubkey, "author pubkey")

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

    def validate_hex32!(value, label)
      return if value.to_s.match?(HEX_32)

      raise InvalidReferenceError, "Invalid #{label}"
    end

    private

    def sign_on_relay(relay_url, account, sign_request_event, request_id, unsigned_event, deadline)
      uri = URI.parse(relay_url)
      backoff = 1
      socket = nil

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
        write_message(socket, req, deadline)

        write_message(socket, ["EVENT", sign_request_event], deadline)

        while Time.now < deadline
          ready = WebsocketConnection.readable_now?(socket) ||
            IO.select([socket], nil, nil, WebsocketConnection.select_timeout(deadline))
          next unless ready

          data = read_websocket_frame(socket, deadline: deadline)
          break unless data

          begin
            # L8: relay/signer-supplied strings are logged with .inspect so an
            # embedded newline cannot forge log entries.
            parsed = JSON.parse(data)
            case parsed[0]
            when "OK"
              # Only the OK for the request event we just published is ours;
              # an OK for anything else must not abort this relay's attempt.
              next unless parsed[1] == sign_request_event["id"]

              accepted = parsed[2]
              Rails.logger.info("NIP-46: Relay #{relay_url} #{accepted ? 'accepted' : 'REJECTED'} sign_event#{accepted ? '' : ": #{parsed[3].inspect}"}")
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
              Rails.logger.info("NIP-46: Decrypted response on #{relay_url}: id=#{response["id"].inspect} has_result=#{response["result"].present?} has_error=#{response["error"].present?}")
              next unless response["id"] == request_id

              if response["result"] == "auth_url"
                log_auth_challenge(response["error"], request_id, relay_url)
                next
              end

              if response["error"].present?
                Rails.logger.warn("NIP-46: Signer error for #{request_id}: #{response["error"].inspect}")
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
              Rails.logger.info("NIP-46: Relay #{relay_url} notice: #{parsed[1].inspect}")
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
    ensure
      # request_signature kills these threads at the deadline; without this the
      # socket (and its TLS session) leaks until GC.
      socket&.close rescue nil
    end

    def decrypt_nip44_or_nip04(content, pubkey, privkey)
      Nip46Envelope.decrypt(content, pubkey, privkey, context: "NIP-46 signer response")
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
      write_message(socket, ["CLOSE", sub_id], 1.second.from_now) rescue nil
      socket.close rescue nil
    end

    def signing_relays
      self.class.signing_relays(@config)
    end

    def build_and_sign_nip46_event(content:, recipient_pubkey:, sender_privkey:, sender_pubkey:)
      Nip46Envelope.build(
        content: content,
        recipient_pubkey: recipient_pubkey,
        sender_privkey: sender_privkey,
        sender_pubkey: sender_pubkey
      )
    end

    # WebSocket helpers (same pattern as other services)
    def create_websocket(uri, deadline:)
      WebsocketConnection.open(uri, deadline: deadline)
    end

    def write_message(socket, message, deadline)
      WebsocketConnection.send_text(socket, message.to_json, deadline)
    end

    def read_websocket_frame(socket, deadline:)
      WebsocketFrameReader.read(socket, deadline: deadline)
    rescue WebsocketFrameReader::FrameError
      nil
    end
  end
end
