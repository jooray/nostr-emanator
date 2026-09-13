# frozen_string_literal: true

class CalendarController < ApplicationController
  def index
    @month = parse_month(params[:month])
    @start_date = @month.beginning_of_week(:monday)
    @end_date = @month.end_of_month.end_of_week(:monday)

    # Fetch all scheduled posts and reposts for the month range
    @posts = Post.joins(:account)
      .where(accounts: { user_id: current_user.id })
      .where(scheduled_at: @start_date..@end_date)
      .where.not(status: :draft)
      .includes(:account, :reposts)
      .order(:scheduled_at)

    @reposts = Repost.joins(:account)
      .where(accounts: { user_id: current_user.id })
      .where(scheduled_at: @start_date..@end_date)
      .includes(:account, :post)
      .order(:scheduled_at)

    # Group by date for calendar rendering (in user's timezone)
    user_tz = ActiveSupport::TimeZone[current_user.timezone] || Time.zone
    @events_by_date = {}
    @posts.each do |post|
      date = post.scheduled_at.in_time_zone(user_tz).to_date
      @events_by_date[date] ||= []
      @events_by_date[date] << { type: :post, item: post }
    end
    @reposts.each do |repost|
      date = repost.scheduled_at.in_time_zone(user_tz).to_date
      @events_by_date[date] ||= []
      @events_by_date[date] << { type: :repost, item: repost }
    end

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
