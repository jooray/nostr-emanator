# frozen_string_literal: true

# Resolves `nostr:` references (profiles and notes) off the request path.
#
# `NostrContentHelper` only ever reads the cache; when it misses it enqueues one
# of these and renders the plain fallback. That keeps relay round-trips out of
# view rendering (a cold mention used to add seconds to a dashboard load) while
# still filling the cache for the next render.
class WarmNostrReferenceJob < ApplicationJob
  queue_as :default

  CACHE_TTL = 1.day
  # Long enough that a page full of the same unresolved mention enqueues once,
  # short enough that a failed fetch is retried on a later visit.
  ENQUEUED_TTL = 5.minutes

  class << self
    def profile_cache_key(pubkey_hex) = "nostr_profile:#{pubkey_hex}"
    def event_cache_key(event_id_hex) = "nostr_event:#{event_id_hex}"

    # Enqueues at most one warm-up per identifier per ENQUEUED_TTL.
    def enqueue_once(kind, identifier)
      marker = "nostr_ref_warming:#{kind}:#{identifier}"
      return unless Rails.cache.write(marker, true, expires_in: ENQUEUED_TTL, unless_exist: true)

      perform_later(kind.to_s, identifier)
    rescue StandardError => e
      # Never let a cache/queue hiccup break rendering.
      Rails.logger.warn("WarmNostrReferenceJob: could not enqueue #{kind} #{identifier}: #{e.message}")
      nil
    end
  end

  def perform(kind, identifier)
    case kind.to_s
    when "profile" then warm_profile(identifier)
    when "event" then warm_event(identifier)
    else Rails.logger.warn("WarmNostrReferenceJob: unknown kind #{kind.inspect}")
    end
  end

  private

  def warm_profile(pubkey_hex)
    profile = Nostr::ProfileFetcher.new.fetch(pubkey_hex)
    return if profile.blank?

    Rails.cache.write(self.class.profile_cache_key(pubkey_hex), profile, expires_in: CACHE_TTL)
  rescue StandardError => e
    Rails.logger.warn("Failed to fetch profile #{pubkey_hex}: #{e.message}")
  end

  def warm_event(event_id_hex)
    result = Nostr::EventFetcher.new.fetch_by_ids([ event_id_hex ])
    event = result&.values&.first
    return if event.blank?

    Rails.cache.write(
      self.class.event_cache_key(event_id_hex),
      { content: event["content"], pubkey: event["pubkey"], kind: event["kind"] },
      expires_in: CACHE_TTL
    )
  rescue StandardError => e
    Rails.logger.warn("Failed to fetch event #{event_id_hex}: #{e.message}")
  end
end
