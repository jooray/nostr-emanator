# frozen_string_literal: true

module Api
  module V1
    # Everything scheduled in a span. The app lays out the grid itself, so it
    # asks for instants (from/to), not a month — then a week or agenda view needs
    # no new endpoint.
    class CalendarController < BaseController
      MAX_SPAN = 62.days

      def index
        from = parse(params[:from]) || Time.current.beginning_of_month
        to = parse(params[:to]) || from + 1.month
        to = from + MAX_SPAN if to - from > MAX_SPAN
        span = from..to

        posts = Post.joins(:account).where(accounts: { user_id: current_user.id })
                    .where(scheduled_at: span).where.not(status: :draft)
                    .includes(:account, :reposts).order(:scheduled_at)
        reposts = Repost.joins(:account).where(accounts: { user_id: current_user.id })
                        .where(scheduled_at: span).includes(:account, :post).order(:scheduled_at)

        render json: {
          from: serializer.time(from),
          to: serializer.time(to),
          items: (posts.to_a + reposts.to_a).sort_by(&:scheduled_at).map { |r| serializer.row(r) }
        }
      end

      private

      def parse(value)
        value.present? ? Time.iso8601(value.to_s) : nil
      rescue ArgumentError
        nil
      end
    end
  end
end
