# frozen_string_literal: true

module Nostr
  # Remembers relays that refused an event, so we stop routing to them.
  #
  # Only observed reply targets are filtered by this. A relay the recipient
  # actually nominated in their kind 10050 is still tried every time — that is
  # their stated inbox, and a transient rejection there is not ours to overrule.
  #
  # The case this exists for is real and already live: relay.keychat.io is in
  # Keychat's default relay set, and its NIP-11 document advertises
  # `payment_required` with a 1-sat Cashu fee on exactly kinds 4 and 1059. It
  # accepted an unpaid gift wrap when tested on 2026-08-26, so the fee is
  # advertised but not currently enforced — which is precisely the kind of thing
  # that changes without notice. When it does, every reply to a Keychat contact
  # would otherwise burn a publish attempt on a relay that will never take it.
  #
  # A rejection is remembered rather than treated as permanent because relay
  # policy is a moving target in both directions.
  module RelayWriteBlock
    TTL = 12.hours

    class << self
      def blocked?(relay_url)
        Rails.cache.read(key(relay_url)).present?
      end

      # `:rejected` is the relay saying "OK false" — a policy answer. A timeout or
      # a socket error says nothing about policy and must not block the relay, or
      # one bad afternoon would evict a peer's only working route.
      def observe!(relay_url, result)
        return unless result == :rejected

        Rails.cache.write(key(relay_url), Time.current.to_i, expires_in: TTL)
      end

      def clear!(relay_url) = Rails.cache.delete(key(relay_url))

      private

      def key(relay_url) = "relay_write_block:#{RelayAuth.host(relay_url)}"
    end
  end
end
