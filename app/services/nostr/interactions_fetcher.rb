# frozen_string_literal: true

module Nostr
  class InteractionsFetcher
    def initialize(additional_relays: [])
      @event_fetcher = Nostr::EventFetcher.new(additional_relays: additional_relays)
      @profile_fetcher = Nostr::ProfileFetcher.new(additional_relays: additional_relays)
    end

    # Cache-first render path. Takes pre-fetched raw events (from
    # InteractionsCache), filters out muted authors, builds interaction hashes,
    # and enriches from caches.
    #
    # blocking: true  — cold-miss profiles and original posts are fetched from
    #                   relays inline (best completeness, slowest).
    # blocking: false — use only what's in the caches; missing bits render as
    #                   nil. Use for streaming snapshots so partial results
    #                   reach the browser fast.
    def render_from_cached_events(events, accounts, user, limit: 50, blocking: true)
      return [] if events.blank? || accounts.empty?

      muted = InteractionsCache.read_muted_pubkeys(user)
      filtered = events.reject { |e| muted.include?(e["pubkey"]) }

      pubkey_to_account = accounts.index_by(&:pubkey_hex)
      interactions = build_interactions_from_events(filtered, pubkey_to_account, accounts, limit)

      enrich_from_caches(interactions, accounts, blocking: blocking)
      interactions
    end

    # Relay path: fetch raw events in parallel across relays, stream partial
    # snapshots via the block. Caller owns caching + enrichment.
    def fetch_raw_events_streaming(accounts, since:, limit: 50, relay_limit: 1000, &on_snapshot)
      accounts = Array(accounts)
      return [] if accounts.empty?

      pubkey_hexes = accounts.map(&:pubkey_hex).compact.uniq
      @event_fetcher.fetch_mentions_combined_streaming(
        pubkey_hexes, since: since, limit: relay_limit, &on_snapshot
      )
    end

    # Build interaction hashes in memory from raw relay events.
    def build_interactions_from_events(raw_events, pubkey_to_account, accounts, limit)
      interactions = raw_events.filter_map do |event|
        p_tags = (event["tags"] || []).select { |t| t[0] == "p" }.map { |t| t[1] }
        target_account = p_tags.filter_map { |pk| pubkey_to_account[pk] }.first
        target_account ||= accounts.first

        build_interaction(event, target_account)
      end

      merge_balanced(interactions.uniq { |i| i[:event_id] }, accounts, limit)
    end

    def build_interaction(event, target_account)
      tags = event["tags"] || []
      e_tags = tags.select { |t| t[0] == "e" }
      q_tags = tags.select { |t| t[0] == "q" }

      interaction_type = if q_tags.any?
        :quote
      elsif e_tags.any?
        :reply
      else
        :mention
      end

      target_event_id = pick_target_event_id(interaction_type, e_tags, q_tags)
      referenced_event_ids = ([target_event_id] + e_tags.map { |t| t[1] } + q_tags.map { |t| t[1] }).compact.uniq

      {
        event_id: event["id"],
        author_pubkey: event["pubkey"],
        author_name: nil,
        author_picture: nil,
        content: event["content"],
        created_at: event["created_at"],
        interaction_type: interaction_type,
        target_event_id: target_event_id,
        referenced_event_ids: referenced_event_ids,
        target_account: target_account,
        raw_event: event,
        original_post_content: nil,
        original_post_author: nil,
        original_post_author_pubkey: nil,
        original_post_event_id: nil,
        original_post_db_id: nil,
        original_post_is_owned: false
      }
    end

    # NIP-10: prefer the e-tag explicitly marked "reply"; otherwise the last
    # positional e-tag is the immediate parent. NIP-25 reactions follow the
    # same convention. Quotes use the first q-tag.
    def pick_target_event_id(interaction_type, e_tags, q_tags)
      case interaction_type
      when :quote
        q_tags.first&.dig(1)
      when :reply
        marked = e_tags.find { |t| t[3] == "reply" }
        (marked || e_tags.last)&.dig(1)
      end
    end

    # Enrich interactions. blocking: false skips relay fallbacks (streaming).
    def enrich_from_caches(interactions, accounts, blocking: true)
      enrich_with_profiles(interactions, blocking: blocking)
      enrich_with_original_posts(interactions, accounts, blocking: blocking)
      enrich_with_follow_status(interactions, accounts)
      interactions
    end

    def enrich_with_profiles(interactions, blocking: true)
      pubkeys = interactions.map { |i| i[:author_pubkey] }.compact.uniq

      missing = []
      stale = []
      pubkeys.each do |pubkey|
        raw = InteractionsCache.read_profile(pubkey)
        if raw.nil?
          missing << pubkey
        elsif InteractionsCache.profile_stale?(pubkey)
          stale << pubkey
        end
      end

      if blocking && missing.any?
        fetched = @profile_fetcher.fetch_batch(missing)
        missing.each { |pk| InteractionsCache.write_profile(pk, fetched[pk] || {}) }
        missing = []
      end

      # Anything still uncached in non-blocking mode + anything stale: fire a
      # background refresh so the next render has it.
      to_refresh = (missing + stale)
      CacheRefreshDispatcher.refresh_profiles(to_refresh) if to_refresh.any?

      interactions.each do |interaction|
        profile = InteractionsCache.profile_data(interaction[:author_pubkey]) || {}
        interaction[:author_name] = profile[:display_name] || profile[:username]
        interaction[:author_picture] = profile[:picture]
      end

      interactions
    end

    def enrich_with_original_posts(interactions, accounts, blocking: true)
      unresolved_ids = []
      account_pubkeys = accounts.map(&:pubkey_hex).to_set
      account_ids = accounts.map(&:id)

      interactions.each do |interaction|
        target_id = interaction[:target_event_id]
        next if target_id.blank?

        db_post = Post.where(event_id: target_id, account_id: account_ids).first
        if db_post
          interaction[:original_post_content] = db_post.content
          interaction[:original_post_author] = db_post.account.display_name || db_post.account.username || db_post.account.npub
          interaction[:original_post_author_pubkey] = db_post.account.pubkey_hex
          interaction[:original_post_event_id] = db_post.event_id
          interaction[:original_post_db_id] = db_post.id
          interaction[:original_post_is_owned] = true
          next
        end

        cached_event = InteractionsCache.read_original_post(target_id)
        if cached_event
          apply_original_post(interaction, cached_event, accounts, account_pubkeys)
          next
        end

        unresolved_ids << target_id
      end

      return interactions if unresolved_ids.empty? || !blocking

      unresolved_ids.uniq!
      fetched = @event_fetcher.fetch_by_ids(unresolved_ids)
      fetched.each { |id, event| InteractionsCache.write_original_post(id, event) }

      interactions.each do |interaction|
        next if interaction[:original_post_content].present?
        target_id = interaction[:target_event_id]
        next if target_id.blank?

        event = fetched[target_id]
        apply_original_post(interaction, event, accounts, account_pubkeys) if event
      end

      interactions
    end

    def enrich_with_follow_status(interactions, accounts)
      return interactions if interactions.empty?

      account_ids = accounts.map(&:id)
      interaction_event_ids = interactions.map { |i| i[:event_id] }.compact
      author_pubkeys = interactions.map { |i| i[:author_pubkey] }.compact.uniq

      contact_lists = {}
      account_reactions = {}
      accounts.each do |a|
        contact_lists[a.pubkey_hex] = InteractionsCache.read_contact_list(a.pubkey_hex)
        account_reactions[a.pubkey_hex] = InteractionsCache.read_reactions(a.pubkey_hex)
      end

      existing_reactions = NostrAction.where(
        account_id: account_ids,
        action_type: :reaction,
        target_event_id: interaction_event_ids
      ).where.not(status: :failed).pluck(:account_id, :target_event_id).to_set

      existing_follows = NostrAction.where(
        account_id: account_ids,
        action_type: :follow,
        target_pubkey: author_pubkeys
      ).where.not(status: :failed).pluck(:account_id, :target_pubkey).to_set

      interactions.each do |interaction|
        account = interaction[:target_account]
        next unless account

        author_pk = interaction[:author_pubkey]

        interaction[:already_following] =
          (contact_lists[account.pubkey_hex]&.include?(author_pk) || false) ||
          existing_follows.include?([account.id, author_pk])

        interaction[:already_liked] =
          (account_reactions[account.pubkey_hex]&.include?(interaction[:event_id]) || false) ||
          existing_reactions.include?([account.id, interaction[:event_id]])

        interaction[:relay_hint] = interaction.dig(:raw_event, "_seen_on_relays")&.first || ""
      end

      interactions
    end

    private

    def apply_original_post(interaction, event, accounts, account_pubkeys = nil)
      interaction[:original_post_content] = event["content"]
      interaction[:original_post_event_id] = event["id"]
      interaction[:original_post_author_pubkey] = event["pubkey"]
      author_account = accounts.find { |a| a.pubkey_hex == event["pubkey"] }
      if author_account
        interaction[:original_post_author] =
          author_account.display_name || author_account.username || author_account.npub
        interaction[:original_post_is_owned] = true
      else
        profile = InteractionsCache.profile_data(event["pubkey"]) || {}
        interaction[:original_post_author] = profile[:display_name] || profile[:username]
        account_pubkeys ||= accounts.map(&:pubkey_hex).to_set
        interaction[:original_post_is_owned] = account_pubkeys.include?(event["pubkey"])
      end
    end

    def merge_balanced(interactions, accounts, limit)
      return interactions.sort_by { |i| -i[:created_at] }.first(limit) if accounts.size <= 1

      by_account = interactions.group_by { |i| i[:target_account]&.id }
      min_per_account = 3
      result = []
      remaining = []

      accounts.each do |account|
        sorted = (by_account[account.id] || []).sort_by { |i| -i[:created_at] }
        result.concat(sorted.first(min_per_account))
        remaining.concat(sorted.drop(min_per_account))
      end

      slots_left = limit - result.size
      if slots_left > 0
        remaining.sort_by! { |i| -i[:created_at] }
        result.concat(remaining.first(slots_left))
      end

      result
        .uniq { |i| i[:event_id] }
        .sort_by { |i| -i[:created_at] }
        .first(limit)
    end
  end
end
