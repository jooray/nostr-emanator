# frozen_string_literal: true

module Api
  module V1
    # Replies, mentions, quotes and reactions to every account, read from the
    # same cache the web Interactions page reads — never a relay call in the
    # request. `refreshing` says a background refresh is under way.
    class InteractionsController < BaseController
      def index
        accounts = current_user.accounts.order(:created_at).to_a
        events = InteractionsCache.read_events(current_user)
        interactions =
          if events.present?
            Nostr::InteractionsFetcher.new.render_from_cached_events(events, accounts, current_user)
          else
            []
          end

        render json: {
          interactions: interactions.map { |i| serializer.interaction(i) },
          refreshing: InteractionsCache.events_stale?(current_user),
          loaded: events.present?
        }
      end
    end
  end
end
