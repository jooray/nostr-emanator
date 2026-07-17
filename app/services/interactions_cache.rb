# frozen_string_literal: true

# Central place for all interactions-domain cache keys. Every value is wrapped
# as { data:, fetched_at: } so freshness can be checked in one read.
#
# Design: long TTLs, short staleness thresholds. "Stale" means "serve the cached
# value but fire a non-blocking background refresh". Only a cache miss blocks.
class InteractionsCache
  # TTLs — generous; we rely on stale/fresh checks, not expiry.
  EVENTS_TTL       = 30.days
  MUTED_TTL        = 30.days
  CONTACTS_TTL     = 30.days
  REACTIONS_TTL    = 30.days
  PROFILE_TTL      = 7.days
  PROFILE_EMPTY_TTL = 1.hour
  ORIGINAL_POST_TTL = 30.days
  MUTE_EVENT_TTL   = 30.days
  INFLIGHT_TTL     = 30.seconds

  # Staleness thresholds — when to fire a background refresh.
  EVENTS_STALE_AFTER    = 5.minutes
  MUTED_STALE_AFTER     = 1.hour
  CONTACTS_STALE_AFTER  = 1.hour
  REACTIONS_STALE_AFTER = 1.hour
  PROFILE_STALE_AFTER   = 1.day

  class << self
    # ----- raw interactions events (pre-mute-filter, pre-enrichment) -----

    def events_key(user_id) = "interactions_events_user_#{user_id}"

    def read_events(user)
      unwrap(Rails.cache.read(events_key(user.id)))
    end

    def events_stale?(user)
      stale?(Rails.cache.read(events_key(user.id)), EVENTS_STALE_AFTER)
    end

    def write_events(user, events)
      Rails.cache.write(events_key(user.id), wrap(events), expires_in: EVENTS_TTL)
    end

    # ----- muted pubkeys (union across login user + all managed accounts) -----

    def muted_key(user_id) = "muted_pubkeys_user_#{user_id}"

    def read_muted_pubkeys(user)
      unwrap(Rails.cache.read(muted_key(user.id))) || Set.new
    end

    def muted_stale?(user)
      stale?(Rails.cache.read(muted_key(user.id)), MUTED_STALE_AFTER)
    end

    def muted_missing?(user)
      Rails.cache.read(muted_key(user.id)).nil?
    end

    def write_muted_pubkeys(user, set)
      Rails.cache.write(muted_key(user.id), wrap(Set.new(set)), expires_in: MUTED_TTL)
    end

    # Incremental add after a successful mute publish — avoid waiting for a full sync.
    def add_muted_pubkey(user, pubkey)
      current = read_muted_pubkeys(user)
      write_muted_pubkeys(user, current + [pubkey])
    end

    # ----- full kind-10000 events (needed to append new mutes) -----

    def mute_event_key(pubkey) = "mute_list_event_pubkey_#{pubkey}"

    def read_mute_event(pubkey)
      Rails.cache.read(mute_event_key(pubkey))
    end

    def write_mute_event(pubkey, event)
      Rails.cache.write(mute_event_key(pubkey), event, expires_in: MUTE_EVENT_TTL)
    end

    # ----- contact lists (per account pubkey) -----

    def contacts_key(pubkey) = "contact_list_pubkeys_#{pubkey}"

    def read_contact_list(pubkey)
      unwrap(Rails.cache.read(contacts_key(pubkey))) || Set.new
    end

    def contacts_stale?(pubkey)
      stale?(Rails.cache.read(contacts_key(pubkey)), CONTACTS_STALE_AFTER)
    end

    def contacts_missing?(pubkey)
      Rails.cache.read(contacts_key(pubkey)).nil?
    end

    def write_contact_list(pubkey, set)
      Rails.cache.write(contacts_key(pubkey), wrap(Set.new(set)), expires_in: CONTACTS_TTL)
    end

    # ----- reactions (per account pubkey, recent liked event IDs) -----

    def reactions_key(pubkey) = "reactions_account_#{pubkey}"

    def read_reactions(pubkey)
      unwrap(Rails.cache.read(reactions_key(pubkey))) || Set.new
    end

    def reactions_stale?(pubkey)
      stale?(Rails.cache.read(reactions_key(pubkey)), REACTIONS_STALE_AFTER)
    end

    def reactions_missing?(pubkey)
      Rails.cache.read(reactions_key(pubkey)).nil?
    end

    def write_reactions(pubkey, set)
      Rails.cache.write(reactions_key(pubkey), wrap(Set.new(set)), expires_in: REACTIONS_TTL)
    end

    # ----- profiles -----

    def profile_key(pubkey) = "profile_#{pubkey}"

    def read_profile(pubkey)
      Rails.cache.read(profile_key(pubkey))
    end

    def profile_stale?(pubkey)
      entry = Rails.cache.read(profile_key(pubkey))
      # Legacy unwrapped entries have no fetched_at — treat as stale so they
      # get rewritten in the new format on next refresh.
      return true if entry.is_a?(Hash) && !entry.key?(:fetched_at)
      stale?(entry, PROFILE_STALE_AFTER)
    end

    def write_profile(pubkey, profile)
      profile = profile || {}
      # Empty profiles get a short TTL so a relay miss doesn't poison the cache
      # for a week. After PROFILE_EMPTY_TTL the entry expires, the next render
      # treats it as missing, and a blocking fetch retries — over time the
      # profile fills in as it reaches our relay set.
      ttl = profile.empty? ? PROFILE_EMPTY_TTL : PROFILE_TTL
      Rails.cache.write(profile_key(pubkey), wrap(profile), expires_in: ttl)
    end

    # Profiles are wrapped — helper to get just the data. Tolerates legacy
    # entries written by older code that stored the profile hash directly.
    def profile_data(pubkey)
      entry = read_profile(pubkey)
      return nil if entry.nil?
      return entry[:data] if entry.is_a?(Hash) && entry.key?(:data)
      entry # legacy shape
    end

    # ----- original posts referenced by interactions (immutable) -----

    def original_post_key(event_id) = "original_post_#{event_id}"

    def read_original_post(event_id)
      Rails.cache.read(original_post_key(event_id))
    end

    def write_original_post(event_id, event)
      Rails.cache.write(original_post_key(event_id), event, expires_in: ORIGINAL_POST_TTL)
    end

    # ----- in-flight guards (throttle duplicate refreshes) -----

    # Returns true if the caller successfully claimed the slot. Atomic-ish via
    # Rails.cache.write(unless_exist:). Good enough for a 30 s throttle window.
    def claim_inflight(kind, scope)
      Rails.cache.write(
        "refresh_inflight_#{kind}_#{scope}",
        true,
        expires_in: INFLIGHT_TTL,
        unless_exist: true
      )
    end

    def release_inflight(kind, scope)
      Rails.cache.delete("refresh_inflight_#{kind}_#{scope}")
    end

    private

    def wrap(data)
      { data: data, fetched_at: Time.now.to_i }
    end

    def unwrap(entry)
      entry.is_a?(Hash) ? entry[:data] : nil
    end

    def stale?(entry, threshold)
      return true unless entry.is_a?(Hash) && entry[:fetched_at]
      Time.now.to_i - entry[:fetched_at].to_i > threshold.to_i
    end
  end
end
