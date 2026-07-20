# frozen_string_literal: true

class CalendarController < ApplicationController
  # Tailwind 4's build-time scanner only picks up class names that appear
  # literally in the source. `"bg-#{color}-100"` string interpolation is
  # invisible to it, so those utilities never make it into the compiled CSS
  # and the chips render unstyled. Spell every color's classes out in full here
  # instead, and look them up by name rather than interpolating.
  CHIP_CLASSES = {
    "purple" => {
      post: "bg-purple-100 dark:bg-purple-900/30 text-purple-800 dark:text-purple-200",
      repost: "bg-purple-50 dark:bg-purple-900/20 text-purple-600 dark:text-purple-300"
    },
    "blue" => {
      post: "bg-blue-100 dark:bg-blue-900/30 text-blue-800 dark:text-blue-200",
      repost: "bg-blue-50 dark:bg-blue-900/20 text-blue-600 dark:text-blue-300"
    },
    "green" => {
      post: "bg-green-100 dark:bg-green-900/30 text-green-800 dark:text-green-200",
      repost: "bg-green-50 dark:bg-green-900/20 text-green-600 dark:text-green-300"
    },
    "amber" => {
      post: "bg-amber-100 dark:bg-amber-900/30 text-amber-800 dark:text-amber-200",
      repost: "bg-amber-50 dark:bg-amber-900/20 text-amber-600 dark:text-amber-300"
    },
    "red" => {
      post: "bg-red-100 dark:bg-red-900/30 text-red-800 dark:text-red-200",
      repost: "bg-red-50 dark:bg-red-900/20 text-red-600 dark:text-red-300"
    },
    "pink" => {
      post: "bg-pink-100 dark:bg-pink-900/30 text-pink-800 dark:text-pink-200",
      repost: "bg-pink-50 dark:bg-pink-900/20 text-pink-600 dark:text-pink-300"
    },
    "cyan" => {
      post: "bg-cyan-100 dark:bg-cyan-900/30 text-cyan-800 dark:text-cyan-200",
      repost: "bg-cyan-50 dark:bg-cyan-900/20 text-cyan-600 dark:text-cyan-300"
    },
    "gray" => {
      post: "bg-gray-100 dark:bg-gray-700 text-gray-800 dark:text-gray-200",
      repost: "bg-gray-50 dark:bg-gray-700/60 text-gray-600 dark:text-gray-300"
    }
  }.freeze

  ACCOUNT_COLOR_NAMES = %w[purple blue green amber red pink cyan].freeze

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

    # Account colors for visual coding — pre-resolved to full class strings
    # (see CHIP_CLASSES above) rather than color names.
    @account_chip_classes = {}
    current_user.accounts.each_with_index do |account, i|
      color = ACCOUNT_COLOR_NAMES[i % ACCOUNT_COLOR_NAMES.length]
      @account_chip_classes[account.id] = CHIP_CLASSES.fetch(color)
    end
    @default_chip_classes = CHIP_CLASSES.fetch("gray")
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
