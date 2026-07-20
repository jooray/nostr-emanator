# frozen_string_literal: true

require "securerandom"

module Nostr
  class AuthService
    # Approval window: the QR/listener stays valid only this long. Kept short so
    # an abandoned login frees its worker thread and capacity slot quickly rather
    # than pinning them for the old 30-minute TTL.
    SESSION_EXPIRY = ENV.fetch("NOSTR_AUTH_WINDOW_MINUTES", 5).to_i.minutes
    NIP07_MAX_AGE = 5.minutes
    PERMISSIONS = "get_public_key,sign_event:1,sign_event:3,sign_event:6,sign_event:7,sign_event:10000,sign_event:24242"

    def initialize
      @config = Rails.application.config_for(:emanator)
      @auth_relays = @config.dig(:nostr, :auth_relays) ||
                     [@config.dig(:nostr, :auth_relay)].compact.presence ||
                     ["wss://relay.nsec.app"]
    end

    def generate_connect_uri
      keygen = ::Nostr::Keygen.new
      keypair = keygen.generate_key_pair
      secret = SecureRandom.hex(32)
      session_id = SecureRandom.uuid

      pubkey_hex = keypair.public_key.to_s
      privkey_hex = keypair.private_key.to_s

      auth_session = NostrAuthSession.create!(
        session_id: session_id,
        temp_pubkey: pubkey_hex,
        temp_privkey: privkey_hex,
        secret: secret,
        relay_url: @auth_relays.to_json,
        expires_at: SESSION_EXPIRY.from_now
      )

      app_name = "Emanator"
      relay_params = @auth_relays.map { |r| "relay=#{CGI.escape(r)}" }.join("&")
      metadata = "secret=#{secret}&name=#{CGI.escape(app_name)}&perms=#{CGI.escape(PERMISSIONS)}&url=#{CGI.escape(canonical_url)}"
      uri = "nostrconnect://#{pubkey_hex}?#{relay_params}&#{metadata}"

      {
        uri: uri,
        session_id: session_id,
        relay_urls: @auth_relays
      }
    end

    def check_session(session_id)
      auth_session = NostrAuthSession.active.find_by(session_id: session_id)
      return nil unless auth_session

      if auth_session.authenticated?
        { authenticated: true, pubkey: auth_session.authenticated_user_pubkey }
      else
        { authenticated: false }
      end
    end

    def find_or_create_user(pubkey_hex)
      npub = KeyConverter.hex_to_npub(pubkey_hex)

      user = ::User.find_or_initialize_by(pubkey_hex: pubkey_hex)

      if user.new_record? || user.display_name.blank?
        user.npub = npub
        user.save!

        # H11: the profile fetch is a blocking relay round-trip (up to ~20s)
        # — do it in the background instead of holding the login poll open;
        # the caller already has a usable user record (npub) immediately.
        FetchUserProfileJob.perform_later(user.id)
      end

      user
    end

    def verify_nip07_auth(pubkey_hex, signed_event, challenge:)
      return false if pubkey_hex.blank? || signed_event.blank? || challenge.blank?

      begin
        event_data = JSON.parse(signed_event)

        return false unless EventValidator.valid?(event_data, kind: 22_242, author: pubkey_hex)
        return false unless event_data["created_at"].between?(NIP07_MAX_AGE.ago.to_i, 1.minute.from_now.to_i)
        return false unless event_data["tags"].include?(["challenge", challenge])
        return false unless event_data["tags"].include?(["domain", URI(canonical_url).host])

        true
      rescue JSON::ParserError, StandardError => e
        Rails.logger.error("NIP-07 auth verification failed: #{e.message}")
        false
      end
    end

    def cleanup_expired_sessions
      NostrAuthSession.cleanup_expired!
    end

    def canonical_url
      @config.dig(:app, :canonical_url) || "https://emanator.cypherpunk.today"
    end
  end
end
