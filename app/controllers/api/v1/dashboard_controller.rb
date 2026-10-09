# frozen_string_literal: true

module Api
  module V1
    # The same board as the web dashboard (Dashboard::Board), section by section.
    class DashboardController < BaseController
      def show
        board = Dashboard::Board.new(current_user)
        render json: {
          has_accounts: board.has_accounts?,
          waiting: board.waiting.map { |r| serializer.row(r) },
          unreached: board.unreached.map { |r| serializer.row(r) },
          upcoming: board.upcoming.map { |r| serializer.row(r) },
          failed: board.failed.map { |r| serializer.row(r) },
          failed_total: board.failed_total,
          recent: board.recent.map { |r| serializer.row(r) },
          held_count: board.held_count,
          summary: Dashboard::StationStatus.for(current_user)
        }
      end
    end
  end
end
