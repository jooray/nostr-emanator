# frozen_string_literal: true

module Scheduling
  class SchedulerService
    def initialize(timezone: "UTC")
      @tz = ActiveSupport::TimeZone[timezone] || Time.zone
    end

    # Suggest the next available slot for a post
    def suggest_next_slot(account)
      last_scheduled = account.posts.where.not(scheduled_at: nil)
        .where(status: [:scheduled, :awaiting_signature])
        .order(scheduled_at: :desc)
        .first

      if last_scheduled
        suggest_after(last_scheduled.scheduled_at)
      else
        # No scheduled posts - suggest tomorrow at a random time
        random_time_on_day(Date.current.in_time_zone(@tz).to_date + 1.day)
      end
    end

    private

    def suggest_after(last_time)
      # Next day after the last scheduled post (in user's timezone),
      # but never earlier than tomorrow.
      tomorrow = Date.current.in_time_zone(@tz).to_date + 1.day
      candidate = last_time.in_time_zone(@tz).to_date + 1.day
      next_day = [candidate, tomorrow].max
      random_time_on_day(next_day)
    end

    def random_time_on_day(date)
      # Random time between 9:00 and 21:00 in user's timezone
      hour = rand(9..20)
      minute = rand(0..59)
      @tz.local(date.year, date.month, date.day, hour, minute)
    end
  end
end
