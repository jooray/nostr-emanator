# frozen_string_literal: true

module Nostr
  # Turns the NIP-19 references inside a note's text into the tags a client
  # actually reads (NIP-27 mentions, NIP-18 quotes, NIP-24 hashtags).
  #
  # Without these the post still *looks* right in a client that linkifies the
  # `nostr:` URI, but nobody gets notified and no quote card is drawn: the
  # notification and the quote-repost relationship both live in the tags, not
  # in the content.
  #
  #   nostr:nprofile1… / nostr:npub1…  ->  ["p", <pubkey>, <relay hint>]
  #   nostr:nevent1…   / nostr:note1…  ->  ["q", <id>, <relay hint>, <author>]
  #                                        plus a ["p", <author>] so the quoted
  #                                        author is notified
  #   nostr:naddr1…                    ->  ["a", "<kind>:<pubkey>:<d>", <hint>]
  #   #hashtag                         ->  ["t", "hashtag"]
  #
  # A `q` tag on a kind 1 *is* the quote repost — NIP-18 reserves kind 6 for a
  # plain repost with no commentary of its own.
  class ContentTagger
    def self.tags_for(content, **kwargs) = new(content, **kwargs).tags

    # exclude_event_ids / exclude_pubkeys keep us from restating what a caller
    # has already tagged: a reply's parent is an `e` tag, and re-adding it as a
    # `q` would tell clients the note quotes the thing it is answering.
    def initialize(content, author_pubkey: nil, exclude_event_ids: [], exclude_pubkeys: [], allow_fetch: false)
      @content = content.to_s
      @author_pubkey = author_pubkey
      @exclude_event_ids = Array(exclude_event_ids).compact.to_set
      # The author's own pubkey is excluded by default: the note is already
      # theirs, and a self-`p` puts every post the account writes into its own
      # mentions/interactions feed.
      @exclude_pubkeys = (Array(exclude_pubkeys).compact + Array(author_pubkey).compact).to_set
      @allow_fetch = allow_fetch
      @author_cache = {}
    end

    def tags
      quote_tags = []
      mention_hints = {} # pubkey => relay hint, first one wins

      ContentRefs.scan(@content).each do |ref|
        case ref.type
        when :npub, :nprofile
          record_mention(mention_hints, ref.pubkey, ref.relays.first)
        when :nevent, :note
          quote = quote_tag(ref, mention_hints)
          quote_tags << quote if quote
        when :naddr
          quote = address_tag(ref, mention_hints)
          quote_tags << quote if quote
        end
      end

      mention_tags = mention_hints.map do |pubkey, hint|
        hint.present? ? ["p", pubkey, hint] : ["p", pubkey]
      end

      quote_tags + mention_tags + ContentRefs.hashtags(@content).map { |tag| ["t", tag] }
    end

    private

    def quote_tag(ref, mention_hints)
      # add? returns nil when the id is already there, which covers both the
      # caller's exclusions and a second mention of the same note.
      return nil unless @exclude_event_ids.add?(ref.event_id)

      hint = ref.relays.first.to_s
      author = ref.author || resolve_author(ref.event_id)
      record_mention(mention_hints, author, hint) if author

      # The 4th element is positional, so the relay slot has to be present (even
      # empty) for a reader to find the author.
      author ? ["q", ref.event_id, hint, author] : ["q", ref.event_id, hint]
    end

    def address_tag(ref, mention_hints)
      coordinate = "#{ref.kind}:#{ref.pubkey}:#{ref.identifier}"
      return nil unless @exclude_event_ids.add?(coordinate)

      hint = ref.relays.first.to_s
      record_mention(mention_hints, ref.pubkey, hint)
      hint.present? ? ["a", coordinate, hint] : ["a", coordinate]
    end

    def record_mention(mention_hints, pubkey, hint)
      return if pubkey.blank? || @exclude_pubkeys.include?(pubkey)

      # First non-blank hint wins; a blank one still records the mention.
      mention_hints[pubkey] = hint.to_s if mention_hints[pubkey].blank?
    end

    # An nevent usually carries its author in a TLV, and then this never runs.
    # A note1 never does, so fall back to what we already know locally before
    # considering the network.
    def resolve_author(event_id)
      return @author_cache[event_id] if @author_cache.key?(event_id)

      @author_cache[event_id] = local_author(event_id) || cached_author(event_id) || fetched_author(event_id)
    end

    def local_author(event_id)
      Post.joins(:account).where(event_id: event_id).pick("accounts.pubkey_hex") ||
        Repost.joins(:account).where(event_id: event_id).pick("accounts.pubkey_hex")
    end

    def cached_author(event_id)
      Rails.cache.read(WarmNostrReferenceJob.event_cache_key(event_id))&.dig(:pubkey).presence
    rescue StandardError
      nil
    end

    # Only signing paths pass allow_fetch. Rendering a post already warms this
    # cache in the background (NostrContentHelper), so by the time a draft is
    # scheduled the answer is normally sitting in the cache above and no relay
    # round-trip happens inside the request.
    def fetched_author(event_id)
      unless @allow_fetch
        WarmNostrReferenceJob.enqueue_once(:event, event_id)
        return nil
      end

      event = Nostr::EventFetcher.new.fetch_by_ids([event_id])&.values&.first
      return nil if event.blank?

      Rails.cache.write(
        WarmNostrReferenceJob.event_cache_key(event_id),
        { content: event["content"], pubkey: event["pubkey"], kind: event["kind"] },
        expires_in: WarmNostrReferenceJob::CACHE_TTL
      )
      event["pubkey"].presence
    rescue StandardError => e
      Rails.logger.warn("ContentTagger: could not resolve author of #{event_id}: #{e.message}")
      nil
    end
  end
end
