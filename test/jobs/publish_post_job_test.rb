# frozen_string_literal: true

require_relative "job_test_helper"

class PublishPostJobTest < ActiveSupport::TestCase
  include JobTestHelper
  include ActiveJob::TestHelper

  def test_publishes_a_scheduled_post
    post = build_post(status: :scheduled, scheduled_at: 1.minute.ago, signed_event: fake_event)

    without_broadcasts do
      with_publisher({ "wss://relay.example" => :ok }) { PublishPostJob.perform_now(post.id) }
    end

    post.reload
    assert_equal "published", post.status
    assert post.published_at.present?
  end

  def test_marks_failed_when_no_relay_accepted_the_event
    post = build_post(status: :scheduled, scheduled_at: 1.minute.ago, signed_event: fake_event)

    without_broadcasts do
      with_publisher({ "wss://relay.example" => :error }) { PublishPostJob.perform_now(post.id) }
    end

    assert_equal "failed", post.reload.status
  end

  # M8: a duplicate run (recurring job re-enqueued while the first is still
  # working) must not publish the same post a second time.
  def test_duplicate_run_does_not_republish_a_post_being_published
    post = build_post(status: :scheduled, scheduled_at: 1.minute.ago, signed_event: fake_event)
    post.update_column(:status, Post.statuses[:publishing])

    published = 0
    publisher_counting = ->(_relays) { published += 1; { "wss://relay.example" => :ok } }

    without_broadcasts do
      with_publisher(publisher_counting) { PublishPostJob.perform_now(post.id) }
    end

    assert_equal 0, published, "a concurrent claim must be refused"
    assert_equal "publishing", post.reload.status
  end

  # M7: a partial relay success schedules an automatic rebroadcast.
  def test_partial_relay_success_schedules_a_rebroadcast
    post = build_post(status: :scheduled, scheduled_at: 1.minute.ago, signed_event: fake_event)

    results = { "wss://a.example" => :ok, "wss://b.example" => :error }

    assert_enqueued_with(job: RebroadcastPostJob) do
      without_broadcasts do
        with_publisher(results) { PublishPostJob.perform_now(post.id) }
      end
    end

    assert_equal "published", post.reload.status
  end

  def test_full_relay_success_does_not_schedule_a_rebroadcast
    post = build_post(status: :scheduled, scheduled_at: 1.minute.ago, signed_event: fake_event)

    assert_no_enqueued_jobs(only: RebroadcastPostJob) do
      without_broadcasts do
        with_publisher({ "wss://a.example" => :ok }) { PublishPostJob.perform_now(post.id) }
      end
    end
  end

  # C4: a broadcast failure must not blow up (and re-run) the publish.
  def test_broadcast_failure_does_not_fail_the_job
    post = build_post(status: :scheduled, scheduled_at: 1.minute.ago, signed_event: fake_event)

    raising_broadcast = ->(*_args, **_kwargs) { raise "cable is down" }

    stub_class_method(Turbo::StreamsChannel, :broadcast_replace_to, raising_broadcast) do
      with_publisher({ "wss://a.example" => :ok }) { PublishPostJob.perform_now(post.id) }
    end

    assert_equal "published", post.reload.status
  end

  def test_missing_post_is_discarded_rather_than_raising
    assert_nothing_raised { PublishPostJob.perform_now(0) }
  end
end
