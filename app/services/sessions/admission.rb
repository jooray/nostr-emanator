# frozen_string_literal: true

module Sessions
  # Admits one new pending NIP-46 login, web or app alike. One multiplexed
  # supervisor (Nostr::Nip46Supervisor) serves every pending login with O(1)
  # DB/WebSocket connections, so the cap only guards memory and relay
  # subscription fan-out.
  module Admission
    MAX_ACTIVE_AUTH_SESSIONS = ENV.fetch("MAX_ACTIVE_NOSTR_AUTH_SESSIONS", 50).to_i
    LOCK_KEY = "nostr-auth-session-admission"

    # Yields when there is room and returns the block's value; returns nil
    # (without yielding) when at capacity.
    def self.admit
      # Serialize session creation so a burst can't slip past the capacity check.
      token = SecureRandom.hex(16)
      return nil unless Rails.cache.write(LOCK_KEY, token, expires_in: 10.seconds, unless_exist: true)

      begin
        NostrAuthSession.cleanup_expired!
        return nil if NostrAuthSession.active.where(authenticated_pubkey: nil).count >= MAX_ACTIVE_AUTH_SESSIONS

        yield
      ensure
        Rails.cache.delete(LOCK_KEY) if Rails.cache.read(LOCK_KEY) == token
      end
    end
  end
end
