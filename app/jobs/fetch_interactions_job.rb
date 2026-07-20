# frozen_string_literal: true

# Fetches raw interaction events from relays, caches them, enriches, and
# broadcasts the rendered list to the user's Turbo Stream. Fired only when
# the interactions cache is stale or missing (CacheRefreshDispatcher-guarded).
class FetchInteractionsJob < ApplicationJob
  queue_as :default

  DEFAULT_SINCE = 1.month

  def perform(user_id, stream_name: nil)
    user = User.find_by(id: user_id)
    return unless user

    accounts = user.accounts.to_a
    return if accounts.empty?

    stream_name ||= self.class.stream_name_for(user)
    all_relays = accounts.flat_map { |a| a.write_relays || [] }.compact.uniq
    fetcher = Nostr::InteractionsFetcher.new(additional_relays: all_relays)

    since = DEFAULT_SINCE.ago

    # Streaming: each relay completion yields a snapshot. Non-blocking render
    # uses only cached enrichment so partials reach the browser fast — no
    # 5-10 s relay round-trips per snapshot.
    raw_events = fetcher.fetch_raw_events_streaming(accounts, since: since) do |snapshot|
      partial = fetcher.render_from_cached_events(snapshot, accounts, user, blocking: false)
      broadcast(stream_name, partial)
    end

    InteractionsCache.write_events(user, raw_events)

    # Final render: blocking enrichment populates profiles / original posts
    # that weren't yet cached.
    interactions = fetcher.render_from_cached_events(raw_events, accounts, user, blocking: true)
    broadcast(stream_name, interactions)
    clear_loading_toast(stream_name)
  ensure
    InteractionsCache.release_inflight(:interactions, "user_#{user_id}")
  end

  def self.stream_name_for(user)
    "interactions_user_#{user.id}"
  end

  private

  # Morph the target so existing DOM nodes (e.g. <img> for avatars) are
  # updated in place rather than replaced — avoids avatar flicker and
  # preserves Stimulus controller state across refreshes.
  def broadcast(stream_name, interactions)
    html = ApplicationController.render(
      partial: "interactions/interactions_content",
      locals: { interactions: interactions }
    )

    Turbo::StreamsChannel.broadcast_action_to(
      stream_name,
      action: :replace,
      target: "interactions_content",
      attributes: { method: "morph" },
      html: html
    )
  end

  def clear_loading_toast(stream_name)
    Turbo::StreamsChannel.broadcast_replace_to(
      stream_name,
      target: "interactions_loading_toast",
      html: '<div id="interactions_loading_toast"></div>'
    )
  end
end
