# frozen_string_literal: true

module Messaging
  # Where a peer's gift wraps actually arrived, as reply targets.
  #
  # This exists because a kind 10050 is not the only evidence of where somebody
  # can be reached, and for two widely-used clients it is not evidence at all:
  #
  #   Keychat has no concept of kind 10050 — `sendNip17Message` publishes to every
  #           relay it is connected to. Its users therefore look, to a
  #           spec-following sender, exactly like people who "are not ready to
  #           receive messages", when in fact they are listening on five relays.
  #
  #   0xchat  consults the recipient's list first, but falls back to the SENDER'S
  #           own general relays when none of the recipient's are connectable — so
  #           the relay their message reached us on is often not on either party's
  #           published list.
  #
  # In both cases the client reads from the same pool it writes to, which is what
  # makes a relay we saw them publish on a good place to answer them.
  #
  # Deliberately NOT stored in DmRelayList: that table answers "has this pubkey
  # published a DM inbox?", and a definitive negative there drives the legacy
  # NIP-04 downgrade offer. Folding observations into it would turn "they never
  # published a 10050" into "they did", silently changing what the UI tells the
  # user about a peer's setup.
  module ObservedRelays
    # Enough history to survive a peer switching relays without pinning us to one
    # they abandoned months ago.
    LOOKBACK = 40
    # Reply targets contributed by observation. Small on purpose: these are
    # appended to the recipient's own tier, and every extra relay is one more
    # party that learns somebody gift-wrapped this pubkey.
    MAX_RELAYS = 3

    class << self
      # Relays this peer's inbound messages arrived on, newest sighting first.
      # Returns [] when the feature is off, so callers need no flag of their own.
      def for(conversation, pubkey)
        return [] unless enabled?
        return [] if conversation.blank? || pubkey.blank?

        rows = conversation.messages
                           .where(direction: "inbound", sender_pubkey: pubkey.to_s.downcase)
                           .order(sort_at: :desc)
                           .limit(LOOKBACK)
                           .pluck(:relays)

        rank(rows)
      end

      def enabled?
        Rails.application.config_for(:emanator).dig(:messaging, :reply_to_observed_relays) != false
      end

      private

      # Newest-first, deduped, and dropped if the relay has since refused our
      # writes. `pluck` on a json column hands back a String under MariaDB (the
      # column is LONGTEXT there) and an Array under SQLite, so normalise both.
      def rank(rows)
        rows.flat_map { |value| decode(value) }
            .map { |url| url.to_s.strip }
            .reject(&:blank?)
            .uniq
            .select { |url| Security::UrlGuard.safe_relay?(url) }
            .reject { |url| Nostr::RelayWriteBlock.blocked?(url) }
            .first(MAX_RELAYS)
      end

      def decode(value)
        return Array(value) unless value.is_a?(String)

        JSON.parse(value)
      rescue JSON::ParserError
        []
      end
    end
  end
end
