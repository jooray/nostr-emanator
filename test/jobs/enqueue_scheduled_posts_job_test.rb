# frozen_string_literal: true

require_relative "job_test_helper"

class EnqueueScheduledPostsJobTest < ActiveSupport::TestCase
  include JobTestHelper
  include ActiveJob::TestHelper

  def test_enqueues_due_signed_posts
    post = build_post(status: :scheduled, scheduled_at: 1.minute.ago, signed_event: fake_event)

    assert_enqueued_with(job: PublishPostJob, args: [post.id]) do
      EnqueueScheduledPostsJob.perform_now
    end
  end

  def test_ignores_posts_scheduled_in_the_future
    build_post(status: :scheduled, scheduled_at: 1.hour.from_now, signed_event: fake_event)

    assert_no_enqueued_jobs(only: PublishPostJob) { EnqueueScheduledPostsJob.perform_now }
  end

  # M10: a repost must never publish before its original.
  def test_holds_due_reposts_whose_original_has_not_published
    post = build_post(status: :scheduled, scheduled_at: 1.minute.ago, signed_event: fake_event)
    repost = build_repost(post: post, status: :scheduled, scheduled_at: 1.minute.ago, signed_event: fake_event)

    assert_no_enqueued_jobs(only: PublishRepostJob) { EnqueueScheduledPostsJob.perform_now }
    assert_equal "scheduled", repost.reload.status
  end

  def test_fails_due_reposts_whose_original_failed
    post = build_post(status: :scheduled, scheduled_at: 1.minute.ago, signed_event: fake_event)
    repost = build_repost(post: post, status: :scheduled, scheduled_at: 1.minute.ago, signed_event: fake_event)
    post.update_column(:status, Post.statuses[:failed])

    assert_no_enqueued_jobs(only: PublishRepostJob) { EnqueueScheduledPostsJob.perform_now }

    repost.reload
    assert_equal "failed", repost.status
    assert_match(/original post failed/i, repost.publish_results["error"])
  end

  def test_enqueues_due_reposts_of_published_posts
    post = build_post(status: :scheduled, scheduled_at: 10.minutes.ago, signed_event: fake_event)
    repost = build_repost(post: post, status: :scheduled, scheduled_at: 1.minute.ago, signed_event: fake_event)
    post.update_columns(status: Post.statuses[:published], published_at: Time.current)

    assert_enqueued_with(job: PublishRepostJob, args: [repost.id]) do
      EnqueueScheduledPostsJob.perform_now
    end
  end
end
