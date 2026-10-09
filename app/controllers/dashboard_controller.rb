# frozen_string_literal: true

class DashboardController < ApplicationController
  # See Dashboard::Board for what loads and why, in that order.
  def index
    board = Dashboard::Board.new(current_user)

    @waiting = board.waiting
    @unreached = board.unreached
    @upcoming = board.upcoming
    @failed = board.failed
    @failed_total = board.failed_total
    @recent = board.recent
    @held_count = board.held_count
    @has_accounts = board.has_accounts?
  end
end
