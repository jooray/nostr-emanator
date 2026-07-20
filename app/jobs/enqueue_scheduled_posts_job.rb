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
          .includes(:post)
          .find_each do |repost|
      enqueue_repost(repost)
    end
  end

  private

  # M10: a repost must never publish before (or instead of) its original.
  def enqueue_repost(repost)
    post = repost.post

    if post.nil? || post.published?
      PublishRepostJob.perform_later(repost.id)
    elsif post.failed?
      repost.update!(status: :failed,
                     publish_results: { "error" => "Original post failed to publish" })
      Rails.logger.warn("EnqueueScheduledPostsJob: failing repost #{repost.id}; original post #{post.id} failed")
    else
      # The original hasn't published yet (congestion, still signing) — leave the
      # repost scheduled and pick it up on a later tick.
      Rails.logger.info("EnqueueScheduledPostsJob: holding repost #{repost.id}; original post #{post.id} is #{post.status}")
    end
  end
end
