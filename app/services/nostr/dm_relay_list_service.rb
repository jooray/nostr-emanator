# frozen_string_literal: true

module Nostr
  # Kind-10050 DM relay lists: resolving other people's, and publishing our own.
  #
  # This is the asymmetric part of NIP-17, and getting the asymmetry right is the
  # whole job:
  #
  #   SENDING is strict. "Clients MUST only publish events to the relays listed in
  #   the recipient's kind 10050 event. If such a list is not found that indicates
  #   the user is not ready to receive messages and clients shouldn't try."
  #   Falling back to their public relays leaks that the DM exists AND still fails
  #   to deliver, because they are not watching those relays for wraps.
  #
  #   RECEIVING is unconstrained by the spec, so we cast a wide net. Several
  #   clients (0xchat, NDK, applesauce) do have send-side fallbacks, so wraps
  #   addressed to us genuinely do land outside our 10050. Subscribing to more
  #   relays can only find more of our own messages.
  #
  # Does NOT reuse RelayListFetcher#parse_relay_list: NIP-65 uses `["r", url,
  # marker]`, kind 10050 uses `["relay", url]` with no markers. Different tag,
  # different parser, same UrlGuard discipline.
  class DmRelayListService
    TIMEOUT = 5
    # NIP-17 asks clients to keep these lists to 1-3 entries; 6 is a generous cap
    # on what we will accept from someone else's list.
    MAX_RELAYS = DmRelayList::MAX_RELAYS
    # How many relays to read our own gift wraps from. Each one is a live
    # subscription, so this is a resource bound rather than a policy.
    MAX_INBOX_RELAYS = 8
    # How many relays a single 10050 probe will fan out to. Each is a thread and
    # a socket, and phase 2 of fetch! feeds this somebody ELSE'S NIP-65 write
    # list, which can be arbitrarily long.
    MAX_PROBE_RELAYS = 8

    def initialize
      @config = Rails.application.config_for(:emanator)
    end

    # Cached list for a pubkey, refreshing only when stale. Returns a DmRelayList
    # (possibly one with missing: true) or nil if we have never resolved it.
    def cached(pubkey_hex)
      DmRelayList.for_pubkey(pubkey_hex)
    end

    # Resolve, using the cache unless it is stale. Blocks on relay I/O when it has
    # to, so keep it out of the request path.
    def resolve(pubkey_hex)
      existing = cached(pubkey_hex)
      return existing if existing && !existing.stale?

      fetch!(pubkey_hex)
    end

    # Two-phase lookup, so a cache miss is never mistaken for "this person has no
    # DM inbox". Phase 2 exists because the outbox model says a person's own
    # events live on their write relays — an indexer simply may not carry it.
    #
    # Every query here goes through RelayQuery, which does not implement NIP-42,
    # so the probe is inherently unauthenticated. That is required, not incidental:
    # answering an AUTH challenge would tell the relay "this identity wants to DM
    # <pubkey>", which is a worse leak than the one we are avoiding.
    def fetch!(pubkey_hex)
      pubkey_hex = pubkey_hex.to_s.downcase
      return nil unless pubkey_hex.match?(/\A[0-9a-f]{64}\z/)

      event = query(indexer_relays, pubkey_hex)
      event ||= query(outbox_relays_for(pubkey_hex), pubkey_hex)

      return store(pubkey_hex, event) if event

      # Only now is the negative definitive.
      DmRelayList.definitive_negative!(pubkey_hex)
    end

    Targets = Data.define(:relays, :tier) do
      # Only `inbox` is what NIP-17 actually asks for; the rest are best effort.
      def compliant? = tier == :inbox
      def any? = relays.any?
    end

    # Where to publish a gift wrap for this pubkey, in descending order of how
    # much the recipient asked for it:
    #
    #   inbox    their kind 10050 — designated for DMs, they are listening
    #   nip65    their NIP-65 read relays — not designated, but where their
    #            client generally connects
    #   fallback popular relays — a guess, viable only because every client we
    #            examined reads kind 1059 across its whole pool
    #
    # NIP-17 says to publish only to the 10050 and otherwise not to try. Taken
    # literally that refuses ~two thirds of real contacts, and it is incoherent
    # next to the kind-4 downgrade we offer instead: a gift wrap on a public relay
    # reveals only that *someone* messaged this pubkey, because the wrap is signed
    # by a throwaway key, whereas a kind 4 publishes the whole social-graph edge
    # in the clear. The lower tiers leak strictly less than the alternative the
    # user would otherwise reach for.
    def publish_targets(pubkey_hex)
      list = resolve(pubkey_hex)
      return Targets.new(relays: list.relays.first(MAX_RELAYS), tier: :inbox) if list&.deliverable?

      read = safe_relays(nip65_read_relays(pubkey_hex))
      return Targets.new(relays: read.first(MAX_RELAYS), tier: :nip65) if read.any?

      Targets.new(relays: safe_relays(fallback_relays).first(MAX_RELAYS), tier: :fallback)
    end

    # The wide union we listen on for our own inbound wraps:
    #   our kind 10050  ∪  our NIP-65 read relays  ∪  the app's configured relays
    def inbox_relays_for(account)
      own = cached(account.pubkey_hex)&.relays || []

      (own + Array(account.read_relays) + configured_relays)
        .map { |url| normalize(url) }
        .reject(&:blank?)
        .uniq
        .select { |url| safe?(url) }
        .first(MAX_INBOX_RELAYS)
    end

    # Relay lists write "wss://nos.lol/" while our config writes "wss://nos.lol",
    # and a plain uniq treats those as two relays — so we opened two sockets and
    # ran two subscriptions against the same host, receiving every gift wrap
    # twice.
    def normalize(url)
      url.to_s.strip.sub(%r{/+\z}, "")
    end

    # Publish this account's own kind 10050.
    #
    # NEVER call this without an explicit user action. Kind 10050 is replaceable,
    # so publishing overwrites whatever the account's other clients (Amethyst,
    # 0xchat) configured — the one point every participant in nostrability#169
    # agreed on. `preserve_other_tags` keeps anything the previous version carried
    # that we do not understand.
    def publish_own!(account, urls)
      relays = Array(urls).map { |u| u.to_s.strip }.reject(&:blank?).select { |u| safe?(u) }.uniq.first(MAX_RELAYS)
      raise ArgumentError, "refusing to publish an empty DM relay list" if relays.empty?

      tags = preserve_other_tags(account.pubkey_hex) + relays.map { |url| [ "relay", url ] }
      unsigned = EventSignerService.new.build_unsigned_event(
        content: "", kind: Nip17::RELAY_LIST_KIND, pubkey: account.pubkey_hex,
        created_at: Time.now.to_i, tags: tags
      )

      signed = EventSignerService.new.request_signature(account, unsigned)
      return nil unless signed

      # A 10050 is a public discovery document, so the usual relay defaults are
      # correct here — unlike a gift wrap.
      results = EventPublisherService.new.publish(signed, relays: account.write_relays)
      store(account.pubkey_hex, signed) if results.value?(:ok)

      { event: signed, results: results }
    end

    private

    # Fan out, then take the NEWEST result.
    #
    # This used to walk the relays one at a time and return the first hit, which
    # was wrong twice over: with a 5 s timeout each, six unreachable relays cost
    # 30 s before we could call a lookup negative — long enough that a slow probe
    # looked like "this person has no DM inbox"; and kind 10050 is replaceable, so
    # the first relay to answer is not necessarily the one holding the current
    # version.
    def query(relay_urls, pubkey_hex)
      relays = Array(relay_urls).uniq.first(MAX_PROBE_RELAYS)
      return nil if relays.empty?

      filter = { "kinds" => [ Nip17::RELAY_LIST_KIND ], "authors" => [ pubkey_hex ], "limit" => 1 }

      threads = relays.map do |relay_url|
        Thread.new do
          RelayQuery.run(
            relay_url, filter, timeout: TIMEOUT, stop_after_first: true,
            kind: Nip17::RELAY_LIST_KIND, author: pubkey_hex
          ) || []
        rescue StandardError => e
          Rails.logger.warn("DM relay list lookup failed on #{relay_url.inspect}: #{e.message}")
          []
        end
      end

      threads.flat_map(&:value).max_by { |event| event["created_at"].to_i }
    end

    def store(pubkey_hex, event)
      relays = parse_relays(event)
      record = DmRelayList.find_or_initialize_by(pubkey_hex: pubkey_hex)

      # Newest 10050 wins; an older replaceable event arriving from a lagging
      # relay must not roll the list back.
      created_at = Time.at(event["created_at"].to_i).utc
      return record if record.event_created_at.present? && record.event_created_at > created_at

      record.update!(
        relays: relays,
        # A 10050 that exists but lists no usable relays is the same situation as
        # no 10050 at all: nobody can deliver to this person.
        missing: relays.empty?,
        event_created_at: created_at,
        raw_event: event,
        fetched_at: Time.current,
        checked_at: Time.current
      )
      record
    end

    def parse_relays(event)
      Array(event["tags"]).filter_map do |tag|
        next unless tag.is_a?(Array) && tag[0] == "relay" && tag[1].present?

        url = tag[1].to_s.strip
        next unless safe?(url)

        url
      end.uniq.first(MAX_RELAYS)
    end

    # H4: a 10050 is attacker-supplied and the server opens sockets to it.
    def safe?(url)
      return true if Security::UrlGuard.safe_relay?(url)

      Rails.logger.warn("Ignoring unsafe relay #{url.inspect} from a kind 10050")
      false
    end

    def preserve_other_tags(pubkey_hex)
      previous = DmRelayList.for_pubkey(pubkey_hex)&.raw_event
      Array(previous&.dig("tags")).select { |tag| tag.is_a?(Array) && tag[0] != "relay" }
    end

    def nip65_read_relays(pubkey_hex)
      RelayListFetcher.new.fetch_relay_list(pubkey_hex)[:read]
    rescue StandardError => e
      Rails.logger.warn("NIP-65 read-relay lookup failed for #{pubkey_hex.inspect}: #{e.message}")
      []
    end

    def fallback_relays
      Array(@config.dig(:nostr, :fallback_dm_relays)).presence || configured_relays
    end

    def safe_relays(urls)
      Array(urls).map { |url| normalize(url) }.reject(&:blank?).uniq.select { |url| safe?(url) }
    end

    def indexer_relays
      Account.dm_indexer_relays.presence || configured_relays
    end

    def outbox_relays_for(pubkey_hex)
      RelayListFetcher.new.fetch_write_relays(pubkey_hex)
    rescue StandardError => e
      Rails.logger.warn("NIP-65 lookup failed while probing for a 10050: #{e.message}")
      []
    end

    def configured_relays
      Array(@config.dig(:nostr, :relays))
    end
  end
end
