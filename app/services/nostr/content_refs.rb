# frozen_string_literal: true

module Nostr
  # Finds NIP-19 entities (npub / nprofile / nevent / note / naddr) in post text.
  #
  # Pure: no DB, no cache, no network. Two jobs:
  #
  #   * `normalize` rewrites a bare `nprofile1…` into the `nostr:nprofile1…`
  #     URI form NIP-21 requires. Clients only linkify — and only tag-check —
  #     the prefixed form, so a hand-pasted or AI-written draft full of bare
  #     identifiers publishes as a wall of bech32 that mentions nobody.
  #   * `scan` returns the decoded entities so ContentTagger can turn them into
  #     `p` / `q` / `a` tags.
  #
  # Only entities that actually decode are touched: prose that happens to start
  # with "note1" is left exactly as the user wrote it.
  class ContentRefs
    Ref = Struct.new(:type, :bech32, :pubkey, :event_id, :author, :kind, :identifier, :relays, keyword_init: true)

    # bech32 data charset excludes 1, b, i and o. The lookbehind keeps us out of
    # URLs (`https://njump.me/nevent1…`) and out of the middle of a word, and it
    # is what makes normalize idempotent — the `:` of an existing `nostr:`
    # prefix is only ever consumed by the optional group, never re-matched.
    ENTITY_PATTERN = %r{(?<![\w/:@])(nostr:)?((?:npub|nprofile|nevent|note|naddr)1[02-9ac-hj-np-z]{20,})}

    # A hashtag needs at least one letter, so "#1" and "#2026" stay plain text.
    # [[:alpha:]] is Unicode-aware, so #ekonómia tags as written.
    HASHTAG_PATTERN = %r{(?<![\w#/])#([[:alnum:]_]*[[:alpha:]][[:alnum:]_]*)}

    class << self
      # Bare identifier -> `nostr:` URI. Idempotent; leaves undecodable text alone.
      def normalize(content)
        return content if content.blank?

        content.gsub(ENTITY_PATTERN) do
          whole = Regexp.last_match(0)
          next whole if Regexp.last_match(1) # already prefixed

          entity = Regexp.last_match(2)
          decode(entity) ? "nostr:#{entity}" : whole
        end
      end

      # Decoded entities, in the order they appear. Duplicates are kept; the
      # tagger dedupes, since it is the one that knows what a duplicate means.
      def scan(content)
        return [] if content.blank?

        content.to_s.to_enum(:scan, ENTITY_PATTERN).filter_map { decode(Regexp.last_match(2)) }
      end

      def hashtags(content)
        return [] if content.blank?

        content.to_s.scan(HASHTAG_PATTERN).flatten.map(&:downcase).uniq
      end

      def decode(entity)
        case entity
        when /\Anpub1/    then decode_npub(entity)
        when /\Anprofile1/ then decode_nprofile(entity)
        when /\Anevent1/  then decode_nevent(entity)
        when /\Anote1/    then decode_note(entity)
        when /\Anaddr1/   then decode_naddr(entity)
        end
      rescue StandardError
        # KeyConverter raises on malformed bech32; that just means this was not
        # an identifier after all.
        nil
      end

      private

      def decode_npub(entity)
        pubkey = KeyConverter.npub_to_hex(entity)
        return nil unless hex32?(pubkey)

        Ref.new(type: :npub, bech32: entity, pubkey: pubkey, relays: [])
      end

      def decode_nprofile(entity)
        parts = KeyConverter.nprofile_to_components(entity)
        return nil unless parts && hex32?(parts[:pubkey])

        Ref.new(type: :nprofile, bech32: entity, pubkey: parts[:pubkey], relays: relay_hints(parts[:relays]))
      end

      def decode_nevent(entity)
        parts = KeyConverter.nevent_to_hex(entity)
        return nil unless parts && hex32?(parts[:event_id])

        Ref.new(
          type: :nevent,
          bech32: entity,
          event_id: parts[:event_id],
          author: (parts[:author] if hex32?(parts[:author])),
          kind: parts[:kind],
          relays: relay_hints(parts[:relays])
        )
      end

      def decode_note(entity)
        event_id = KeyConverter.note_to_hex(entity)
        return nil unless hex32?(event_id)

        Ref.new(type: :note, bech32: entity, event_id: event_id, relays: [])
      end

      def decode_naddr(entity)
        parts = KeyConverter.naddr_to_components(entity)
        return nil unless parts && hex32?(parts[:pubkey]) && parts[:kind]

        Ref.new(
          type: :naddr,
          bech32: entity,
          pubkey: parts[:pubkey],
          kind: parts[:kind],
          identifier: parts[:identifier].to_s,
          relays: relay_hints(parts[:relays])
        )
      end

      def relay_hints(relays)
        Array(relays).filter_map do |relay|
          url = relay.to_s.strip
          url if url.start_with?("ws://", "wss://")
        end
      end

      def hex32?(value) = value.to_s.match?(/\A[0-9a-f]{64}\z/)
    end
  end
end
