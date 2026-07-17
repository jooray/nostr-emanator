# frozen_string_literal: true

class CalendarController < ApplicationController
  def index
    @month = params[:month] ? Date.parse(params[:month]) : Date.current.beginning_of_month
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

    # Account colors for visual coding
    @account_colors = {}
    colors = %w[purple blue green amber red pink cyan]
    current_user.accounts.each_with_index do |account, i|
      @account_colors[account.id] = colors[i % colors.length]
    end
  end
end
