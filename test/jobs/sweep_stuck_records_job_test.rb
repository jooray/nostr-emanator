# frozen_string_literal: true

require_relative "job_test_helper"

class SweepStuckRecordsJobTest < ActiveSupport::TestCase
  include JobTestHelper

  # C4: a post abandoned mid-publish is failed so the UI offers recovery.
  def test_sweeps_posts_stuck_in_publishing
    post = build_post(status: :scheduled, signed_event: fake_event)
    stall(post, :publishing, 30.minutes.ago)

    SweepStuckRecordsJob.perform_now

    post.reload
    assert_equal "failed", post.status
    assert_match(/did not complete/i, post.publish_results["error"])
    assert post.can_retry_publish?, "user must be able to retry a swept post"
  end

  def test_leaves_recently_publishing_posts_alone
    post = build_post(status: :scheduled, signed_event: fake_event)
    stall(post, :publishing, 2.minutes.ago)

    SweepStuckRecordsJob.perform_now

    assert_equal "publishing", post.reload.status
  end

  # H15: awaiting_signature records nothing will ever touch again.
  def test_sweeps_posts_stuck_awaiting_signature
    post = build_post(status: :awaiting_signature)
    stall(post, :awaiting_signature, 1.hour.ago)

    SweepStuckRecordsJob.perform_now

    assert_equal "failed", post.reload.status
  end

  def test_leaves_recent_awaiting_signature_posts_alone
    post = build_post(status: :awaiting_signature)

    SweepStuckRecordsJob.perform_now

    assert_equal "awaiting_signature", post.reload.status
  end

  # L17: reposts stranded in pending_signature are swept too.
  def test_sweeps_reposts_stuck_in_pending_signature
    post = build_post(status: :scheduled, signed_event: fake_event)
    repost = build_repost(post: post, status: :pending_signature)
    stall(repost, :pending_signature, 45.minutes.ago)

    SweepStuckRecordsJob.perform_now

    assert_equal "failed", repost.reload.status
  end

  def test_sweeps_reposts_stuck_in_publishing
    post = build_post(status: :scheduled, signed_event: fake_event)
    repost = build_repost(post: post, status: :scheduled, signed_event: fake_event)
    stall(repost, :publishing, 30.minutes.ago)

    SweepStuckRecordsJob.perform_now

    assert_equal "failed", repost.reload.status
  end

  def test_reports_the_number_of_swept_records
    post = build_post(status: :awaiting_signature)
    stall(post, :awaiting_signature, 1.hour.ago)

    assert_equal 1, SweepStuckRecordsJob.perform_now
    assert_equal 0, SweepStuckRecordsJob.perform_now
  end

  private

  # Put a record into `status` with an old updated_at, bypassing callbacks.
  def stall(record, status, at)
    record.class.where(id: record.id)
      .update_all(status: record.class.statuses.fetch(status.to_s), updated_at: at)
    record.reload
  end
end
