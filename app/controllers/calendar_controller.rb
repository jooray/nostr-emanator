# frozen_string_literal: true

class CalendarController < ApplicationController
  def index
    @month = parse_month(params[:month])
    @start_date = @month.beginning_of_week(:monday)
    @end_date = @month.end_of_month.end_of_week(:monday)

    # The span is stated as instants, not dates. A bare `@start_date..@end_date`
    # against a datetime column casts both ends to midnight, so everything after
    # 00:00 on the last day of the grid fell outside the range and that cell
    # rendered empty no matter what was scheduled in it.
    #
    # Both ends are now anchored in the user's own zone (ApplicationController
    # sets Time.zone per request), which is the same clock the cells are labelled
    # with — so an event near midnight lands in the cell the operator sees it in.
    span = @start_date.beginning_of_day..@end_date.end_of_day

    @posts = Post.joins(:account)
      .where(accounts: { user_id: current_user.id })
      .where(scheduled_at: span)
      .where.not(status: :draft)
      .includes(:account, :reposts)
      .order(:scheduled_at)

    @reposts = Repost.joins(:account)
      .where(accounts: { user_id: current_user.id })
      .where(scheduled_at: span)
      .includes(:account, :post)
      .order(:scheduled_at)

    # `scheduled_at` already reads in Time.zone, so this bucketing needs no
    # conversion of its own — and cannot drift from what the cell prints.
    @events_by_date = Hash.new { |h, k| h[k] = [] }
    @posts.each { |post| @events_by_date[post.scheduled_at.to_date] << { type: :post, item: post } }
    @reposts.each { |repost| @events_by_date[repost.scheduled_at.to_date] << { type: :repost, item: repost } }

    # Identity colour comes from Account#ink — a hash of the pubkey — so it is
    # stable for the life of the account and identical on every other surface.
    # It used to be ACCOUNT_COLOR_NAMES[i % 7]: accounts 1, 8 and 15 shared a
    # colour, and the whole mapping shifted every time an account was paired,
    # which makes a legend impossible and a colour meaningless.
    #
    # Only the identities that actually appear this month, so the legend is a
    # key to what is on screen rather than a list of everything.
    @legend = (@posts.map(&:account) + @reposts.map(&:account)).uniq.sort_by { |a| a.display_name_or_npub.downcase }
  end

  private

  # `Date.parse(params[:month])` raises on garbage input (`?month=garbage`);
  # fall back to the current month instead of a 500.
  def parse_month(month_param)
    return Date.current.beginning_of_month if month_param.blank?

    Date.parse(month_param).beginning_of_month
  rescue ArgumentError, TypeError
    Date.current.beginning_of_month
  end
end
