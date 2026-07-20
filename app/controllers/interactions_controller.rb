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

  private

  def cached_interactions(accounts)
    events = InteractionsCache.read_events(current_user)
    return nil if events.blank?

    fetcher = Nostr::InteractionsFetcher.new
    fetcher.render_from_cached_events(events, accounts, current_user)
  end
end
