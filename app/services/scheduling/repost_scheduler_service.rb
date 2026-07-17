# frozen_string_literal: true

module Scheduling
  class RepostSchedulerService
    # Schedule reposts for given accounts with random delays
    def schedule_reposts(post, account_ids, max_delay_hours: 24)
      return [] if account_ids.blank?

      accounts = Account.where(id: account_ids, user_id: post.account.user_id)
        .where.not(id: post.account_id) # Don't repost to the same account

      reposts = []

      accounts.each do |account|
        delay_minutes = rand(10..(max_delay_hours * 60))
        repost_time = post.scheduled_at + delay_minutes.minutes

        repost = post.reposts.find_or_initialize_by(account: account)
        repost.assign_attributes(
          status: :pending_signature,
          scheduled_at: repost_time,
          delay_minutes: delay_minutes
        )
        repost.save!
        reposts << repost
      end

      reposts
    end
  end
end
