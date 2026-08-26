# frozen_string_literal: true

class ProcessNostrActionJob < ApplicationJob
  queue_as :default
  retry_on StandardError, wait: 5.seconds, attempts: 2

  # How many of the account's own relays we add to the configured defaults when
  # reading its lists back.
  MAX_ACCOUNT_RELAYS = 8

  def perform(nostr_action_id)
    @action = NostrAction.find(nostr_action_id)
    return if @action.published?

    @signer = Nostr::EventSignerService.new
    @publisher = Nostr::EventPublisherService.new

    if @action.reaction?
      process_reaction
    elsif @action.follow?
      process_follow
    elsif @action.mute?
      process_mute
    end
  rescue => e
    @action&.update!(status: :failed, error_message: e.message.truncate(255))
    raise
  end

  private

  def process_reaction
    @action.update!(status: :awaiting_signature)

    relay_hint = ""
    unsigned = @signer.build_unsigned_event(
      content: "+",
      kind: 7,
      pubkey: @action.account.pubkey_hex,
      created_at: Time.current,
      tags: [
        ["e", @action.target_event_id, relay_hint],
        ["p", @action.target_pubkey],
        ["k", @action.target_event_kind.to_s]
      ]
    )
    @action.update!(unsigned_event: unsigned)

    sign_and_publish
  end

  def process_follow
    @action.update!(status: :processing)

    # Fetch current contact list
    result = fetcher.fetch_replaceable(@action.account.pubkey_hex, 3)
    contact_list = result[:event]

    # Safety: abort if no kind 3 event came back. A first-ever kind 3 is not
    # worth the risk here the way a first-ever mute list is — this event carries
    # the entire social graph, and an account with no contact list at all is far
    # rarer than one whose list simply did not reach us.
    unless contact_list
      @action.update!(status: :failed, error_message: unreachable_message(result, "contact list", "Follow"))
      return
    end

    # H3: refuse to re-sign a list older than the newest one we already signed —
    # a relay replaying a stale kind 3 would otherwise silently drop every
    # follow added since.
    if stale_list?(contact_list)
      @action.update!(status: :failed, error_message: "Relays returned an outdated contact list. Follow aborted to prevent data loss.")
      return
    end

    existing_follows = (contact_list["tags"] || []).select { |t| t[0] == "p" }

    # Safety: abort if p-tags list is empty (likely a relay fetch issue, not a real empty list)
    if existing_follows.empty?
      @action.update!(status: :failed, error_message: "Contact list appears empty. Follow aborted to prevent data loss.")
      return
    end

    # Already following? Mark as published and return
    if existing_follows.any? { |t| t[1] == @action.target_pubkey }
      @action.update!(status: :published)
      return
    end

    # Append new follow
    new_tags = existing_follows + [["p", @action.target_pubkey, "", ""]]

    @action.update!(status: :awaiting_signature)

    unsigned = @signer.build_unsigned_event(
      content: "",
      kind: 3,
      pubkey: @action.account.pubkey_hex,
      created_at: Time.current,
      tags: new_tags
    )
    @action.update!(unsigned_event: unsigned)

    sign_and_publish
  end

  def process_mute
    @action.update!(status: :processing)

    result = fetcher.fetch_replaceable(@action.account.pubkey_hex, Nostr::EventFetcher::KIND_MUTE_LIST)
    mute_event = result[:event]

    # An empty kind 10000 means "first-ever mute" only if a relay actually
    # answered; otherwise signing a one-entry list would replace whatever is
    # really out there. This used to be inferred from whether a kind 3 came back
    # — which is wrong twice over: an account that follows nobody has no kind 3,
    # and a relay that refused the connection is indistinguishable from one that
    # answered "nothing" once fetch has flattened it. fetch_replaceable reports
    # reachability directly, so ask it.
    if mute_event.nil?
      if result[:reachable].zero?
        @action.update!(status: :failed, error_message: unreachable_message(result, "mute list", "Mute"))
        return
      end

      # Relays answered, but we have seen a mute list for this account before —
      # so it exists somewhere we did not just read, and re-signing from nothing
      # would drop everyone on it.
      if cached_list_event
        @action.update!(status: :failed, error_message: "Relays did not return your existing mute list. Mute aborted to prevent data loss.")
        return
      end
    end

    # H3: same replay guard as the follow path (a stale kind 10000 would
    # un-mute everyone muted since).
    if mute_event && stale_list?(mute_event)
      @action.update!(status: :failed, error_message: "Relays returned an outdated mute list. Mute aborted to prevent data loss.")
      return
    end

    existing_tags = (mute_event&.dig("tags") || []).reject do |tag|
      tag[0] == "p" && tag[1] == @action.target_pubkey
    end

    already_muted = (mute_event&.dig("tags") || []).any? { |t| t[0] == "p" && t[1] == @action.target_pubkey }
    if already_muted
      @action.update!(status: :published)
      update_mute_caches(mute_event)
      return
    end

    new_tags = existing_tags + [["p", @action.target_pubkey]]

    @action.update!(status: :awaiting_signature)

    unsigned = @signer.build_unsigned_event(
      content: "",
      kind: 10000,
      pubkey: @action.account.pubkey_hex,
      created_at: Time.current,
      tags: new_tags
    )
    @action.update!(unsigned_event: unsigned)

    sign_and_publish

    # After successful publish, warm the cache with the new event + union.
    if @action.reload.published? && @action.signed_event.present?
      update_mute_caches(@action.signed_event)
    end
  end

  # Reading an account's own lists means asking the relays it publishes to, not
  # just the app's configured defaults — that is where its kind 3 / kind 10000
  # actually live. Capped like a publish: the NIP-65 list is not ours and one
  # thread per relay is not free.
  def fetcher
    account_relays = ((@action.account.write_relays || []) + (@action.account.user.custom_relays || []))
      .uniq
      .first(MAX_ACCOUNT_RELAYS)

    @fetcher ||= Nostr::EventFetcher.new(additional_relays: account_relays)
  end

  def unreachable_message(result, list_name, action_name)
    if result[:reachable].zero?
      "Could not reach any relay to read your #{list_name}. #{action_name} aborted to prevent data loss."
    else
      "Relays returned no #{list_name}. #{action_name} aborted to prevent data loss."
    end
  end

  # H3: relay-supplied replaceable lists (kind 3 / kind 10000) are only usable
  # as a base for re-signing if they are at least as new as the newest version
  # we already know about: the last list of this kind this account signed here,
  # and (for mutes) the cached event. Anything older is a replay.
  def stale_list?(event)
    known = latest_known_created_at
    return false if known.nil?

    event["created_at"].to_i < known
  end

  def latest_known_created_at(cached: cached_list_event)
    signed = @action.account.nostr_actions
      .where(action_type: @action.action_type, status: :published)
      .order(id: :desc)
      .limit(20)
      .filter_map { |action| action.signed_event&.dig("created_at")&.to_i }
      .max

    [ signed, cached&.dig("created_at")&.to_i ].compact.max
  end

  def cached_list_event
    return nil unless @action.mute?
    return @cached_list_event if defined?(@cached_list_event)

    @cached_list_event = InteractionsCache.read_mute_event(@action.account.pubkey_hex)
  end

  def update_mute_caches(event)
    return unless event

    InteractionsCache.write_mute_event(@action.account.pubkey_hex, event)
    InteractionsCache.add_muted_pubkey(@action.account.user, @action.target_pubkey)
  end

  def sign_and_publish
    signed = @signer.request_signature(@action.account, @action.unsigned_event)
    unless signed
      @action.update!(status: :failed, error_message: "Signing timed out. Approve in your signer app.")
      return
    end

    @action.update!(signed_event: signed, event_id: signed["id"], status: :publishing)

    relays = (@action.account.write_relays || []) + (@action.account.user.custom_relays || [])
    results = @publisher.publish(signed, relays: relays)

    success_count = results.values.count { |v| v == :ok }
    if success_count > 0
      @action.update!(status: :published, publish_results: results)
    else
      @action.update!(status: :failed, publish_results: results, error_message: "Publishing failed on all relays")
    end
  end
end
