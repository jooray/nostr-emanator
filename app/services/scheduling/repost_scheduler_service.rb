# frozen_string_literal: true

module Scheduling
  class RepostSchedulerService
    MIN_DELAY_MINUTES = 10
    # I6/L11: one year, matching the MCP tool's clamp.
    MAX_DELAY_HOURS = 8760

    # Schedule reposts for given accounts with random delays
    def schedule_reposts(post, account_ids, max_delay_hours: 24)
      return [] if account_ids.blank?

      # L11: a nil scheduled_at used to blow up mid-flow with NoMethodError,
      # and max_delay_hours <= 0 produced rand(10..0) => nil.
      raise ArgumentError, "post must have a scheduled_at before reposts can be scheduled" if post.scheduled_at.blank?

      max_delay_hours = max_delay_hours.to_i.clamp(1, MAX_DELAY_HOURS)
      max_delay_minutes = [max_delay_hours * 60, MIN_DELAY_MINUTES].max

      accounts = Account.where(id: account_ids, user_id: post.account.user_id)
        .where.not(id: post.account_id) # Don't repost to the same account

      accounts.filter_map { |account| upsert_repost(post, account, max_delay_minutes) }
    end

    private

    def upsert_repost(post, account, max_delay_minutes)
      delay_minutes = rand(MIN_DELAY_MINUTES..max_delay_minutes)

      repost = post.reposts.find_or_initialize_by(account: account)
      repost.assign_attributes(
        status: :pending_signature,
        scheduled_at: post.scheduled_at + delay_minutes.minutes,
        delay_minutes: delay_minutes
      )
      repost.save!
      repost
    rescue ActiveRecord::RecordNotUnique, ActiveRecord::RecordInvalid => e
      # L11: a double-submitted #sign races on the (post_id, account_id) index.
      # The repost already exists — reuse it instead of 500ing mid-flow.
      existing = post.reposts.find_by(account: account)
      raise e if existing.nil?

      Rails.logger.info("RepostSchedulerService: repost for account #{account.id} already exists on post #{post.id}; reusing")
      existing
    end
  end
end
