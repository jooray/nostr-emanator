# frozen_string_literal: true

require "securerandom"

module Nostr
  class AuthService
    # Approval window: the QR/listener stays valid only this long. Kept short so
    # an abandoned login frees its worker thread and capacity slot quickly rather
    # than pinning them for the old 30-minute TTL.
    SESSION_EXPIRY = ENV.fetch("NOSTR_AUTH_WINDOW_MINUTES", 5).to_i.minutes
    NIP07_MAX_AGE = 5.minutes

    # Bumped whenever PERMISSIONS grows. Stamped onto Account#dm_perms_version at
    # pair time, because a signer cannot be asked what it actually granted — the
    # only thing we can know is which set we requested.
    #
    #   1 = pre-messaging (posts, reactions, follows, mutes, Blossom uploads)
    #   2 = adds NIP-17 private messaging
    #   3 = adds the legacy NIP-04 send fallback (sign_event:4, nip04_encrypt)
    PERMISSIONS_VERSION = 3

    # Notes on what is and is not here, because every omission is deliberate:
    #
    # * No bare `sign_event`. Amber's parser drops any entry without a kind
    #   (NostrConnectUtils.kt removes `type == "sign_event" && kind == nil`), so a
    #   bare entry is silently ignored rather than granting everything.
    # * No sign_event:14 or :15 — rumors are UNSIGNED by design; we never ask a
    #   signer to sign one.
    # * No sign_event:1059 — gift wraps are signed locally with a throwaway
    #   ephemeral key, which is what hides the sender from the relay.
    # * No sign_event:5 — only the optional NIP-09 cleanup of superseded
    #   read-state events would need it, and we skip that.
    # * No sign_event:10050 — DmRelayListService#publish_own! can build one, but
    #   nothing reaches it yet (there is no "set my DM inbox" UI). Every entry
    #   here costs QR density, so it goes back in when the feature does.
    #
    # sign_event:13 (the seal) is the one that matters most: kinds 13/14/15/1059
    # are NOT in Amber's "basic" auto-approve set, so without this every single
    # outbound DM raises a prompt on the user's phone.
    #
    # sign_event:22242 is NIP-42 relay auth. Amber stores those permissions per
    # relay host and will AUTO-REJECT the request if the user has a non-empty
    # relay-auth whitelist that omits our relay — which presents as a silently
    # empty inbox, so the UI has to call it out.
    PERMISSIONS = [
      "get_public_key",
      # Existing capabilities (version 1).
      "sign_event:1", "sign_event:3", "sign_event:6", "sign_event:7",
      "sign_event:10000", "sign_event:24242",
      # NIP-17 messaging (version 2).
      "sign_event:13",     # seal
      "sign_event:30078",  # NIP-RS read state
      "sign_event:22242",  # NIP-42 relay auth
      "nip44_encrypt",     # seal the rumor / encrypt read state to ourselves
      "nip44_decrypt",     # unwrap gift wraps (two calls per inbound message)
      # Legacy NIP-04 (version 3). Kind 4 is only ever sent as an explicit,
      # acknowledged downgrade to someone with no kind 10050 — see
      # Message::LEGACY_DOWNGRADE_RISKS. Reading legacy threads needs the decrypt
      # half regardless.
      "sign_event:4",
      "nip04_encrypt",
      "nip04_decrypt"
    ].join(",").freeze

    def initialize
      @config = Rails.application.config_for(:emanator)
      @auth_relays = @config.dig(:nostr, :auth_relays) ||
                     [@config.dig(:nostr, :auth_relay)].compact.presence ||
                     ["wss://relay.nsec.app"]
    end

    # The whole URI becomes a QR code, and past ~600 characters it gets dense
    # enough that phone cameras struggle. The permission string is the single
    # biggest contributor, and CGI.escape was tripling every separator in it —
    # `,` to %2C and `:` to %3A, which is 15 commas and 11 colons of pure waste.
    #
    # Both characters are legal unencoded in a query per RFC 3986 (`:` is allowed
    # outright, `,` is a sub-delim), and Amber's parser splits on exactly these
    # two. Everything else still goes through CGI.escape.
    def escape_perms(perms)
      CGI.escape(perms).gsub("%2C", ",").gsub("%3A", ":")
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
      metadata = "secret=#{secret}&name=#{CGI.escape(app_name)}" \
                 "&perms=#{escape_perms(PERMISSIONS)}&url=#{CGI.escape(canonical_url)}"
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
