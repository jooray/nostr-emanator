# frozen_string_literal: true

class EnqueueScheduledPostsJob < ApplicationJob
  queue_as :default

  def perform
    Post.where(status: :scheduled)
        .where("scheduled_at <= ?", Time.current)
        .where.not(signed_event: nil)
        .find_each do |post|
      PublishPostJob.perform_later(post.id)
    end

    Repost.where(status: :scheduled)
          .where("scheduled_at <= ?", Time.current)
          .where.not(signed_event: nil)
          .find_each do |repost|
      PublishRepostJob.perform_later(repost.id)
    end
  end
end
