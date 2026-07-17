# frozen_string_literal: true

class ProcessNostrActionJob < ApplicationJob
  queue_as :default
  retry_on StandardError, wait: 5.seconds, attempts: 2

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
    fetcher = Nostr::EventFetcher.new
    events = fetcher.fetch(@action.account.pubkey_hex, kinds: [3], limit: 1, include_replies: true)
    contact_list = events.first

    # Safety: abort if no kind 3 event found (relay fetch likely failed)
    unless contact_list
      @action.update!(status: :failed, error_message: "Could not fetch contact list from relays. Follow aborted to prevent data loss.")
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

    fetcher = Nostr::EventFetcher.new
    mute_event = fetcher.fetch(@action.account.pubkey_hex, kinds: [10000], limit: 1, include_replies: true).first

    # Empty kind 10000 could mean "first-ever mute" OR "relays unreachable".
    # Disambiguate by checking if a kind 3 (follow list) comes back — that's
    # near-universal, so its absence signals a broken relay fetch and we abort
    # rather than risk overwriting an existing mute list with a single entry.
    if mute_event.nil?
      follow_probe = fetcher.fetch(@action.account.pubkey_hex, kinds: [3], limit: 1, include_replies: true).first
      if follow_probe.nil?
        @action.update!(status: :failed, error_message: "Could not fetch account state from relays. Mute aborted to prevent data loss.")
        return
      end
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
