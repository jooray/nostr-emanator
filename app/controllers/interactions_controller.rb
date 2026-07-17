# frozen_string_literal: true

class InteractionsController < ApplicationController
  def index
    @accounts = current_user.accounts.order(:created_at).to_a
    @stream_name = FetchInteractionsJob.stream_name_for(current_user)

    @interactions = cached_interactions(@accounts)
    # ApplicationController#trigger_stale_refreshes already dispatches the
    # interactions refresh if the events cache is stale/missing; no need to
    # duplicate it here. We just check the same flag so the toast is shown
    # while the refresh is in flight.
    @refreshing = InteractionsCache.events_stale?(current_user)
  end

  # Fallback: synchronous render if stream is unavailable.
  def list
    accounts = current_user.accounts.to_a

    all_relays = accounts.flat_map { |a| a.write_relays || [] }.compact.uniq
    fetcher = Nostr::InteractionsFetcher.new(additional_relays: all_relays)

    cached_events = InteractionsCache.read_events(current_user)
    @interactions =
      if cached_events.present?
        fetcher.render_from_cached_events(cached_events, accounts, current_user)
      else
        raw = fetcher.fetch_raw_events_streaming(accounts, since: FetchInteractionsJob::DEFAULT_SINCE.ago)
        InteractionsCache.write_events(current_user, raw)
        fetcher.render_from_cached_events(raw, accounts, current_user)
      end

    render layout: false
  rescue StandardError => e
    Rails.logger.error("Failed to fetch interactions: #{e.message}")
    @interactions = []
    render layout: false
  end

  private

  def cached_interactions(accounts)
    events = InteractionsCache.read_events(current_user)
    return nil if events.blank?

    fetcher = Nostr::InteractionsFetcher.new
    fetcher.render_from_cached_events(events, accounts, current_user)
  end
end
