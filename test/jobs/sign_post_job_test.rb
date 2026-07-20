# frozen_string_literal: true

require_relative "job_test_helper"

class SignPostJobTest < ActiveSupport::TestCase
  include JobTestHelper

  # C3: a timing-out job must not stomp a post that a concurrent signer
  # already scheduled (or that already published).
  def test_sign_timeout_does_not_stomp_a_concurrently_scheduled_post
    post = build_post(unsigned_event: { "kind" => 1, "content" => "hello world" })

    timeout_that_races = lambda do |_account, _unsigned|
      # Simulate the other signer winning while this one blocks on Amber.
      Post.where(id: post.id).update_all(status: Post.statuses[:scheduled])
      nil
    end

    without_broadcasts do
      with_signer(timeout_that_races) { SignPostJob.perform_now(post.id) }
    end

    assert_equal "scheduled", post.reload.status
  end

  def test_sign_timeout_does_not_stomp_an_already_published_post
    post = build_post(unsigned_event: { "kind" => 1 })

    timeout_that_races = lambda do |_a, _u|
      Post.where(id: post.id).update_all(status: Post.statuses[:published])
      nil
    end

    without_broadcasts do
      with_signer(timeout_that_races) { SignPostJob.perform_now(post.id) }
    end

    assert_equal "published", post.reload.status
  end

  def test_sign_timeout_fails_a_post_that_is_still_awaiting_signature
    post = build_post(unsigned_event: { "kind" => 1 })

    without_broadcasts do
      with_signer(nil) { SignPostJob.perform_now(post.id) }
    end

    assert_equal "failed", post.reload.status
  end

  def test_successful_signature_schedules_the_post
    post = build_post(unsigned_event: { "kind" => 1 })
    event = fake_event

    without_broadcasts do
      with_signer(event) { SignPostJob.perform_now(post.id) }
    end

    post.reload
    assert_equal "scheduled", post.status
    assert_equal event["id"], post.event_id
    assert_equal event, post.signed_event
  end

  # A late signature must not resurrect a post the user cancelled meanwhile.
  def test_late_signature_is_discarded_when_the_post_left_awaiting_signature
    post = build_post(unsigned_event: { "kind" => 1 })

    racing_success = lambda do |_a, _u|
      Post.where(id: post.id).update_all(status: Post.statuses[:draft])
      fake_event
    end

    without_broadcasts do
      with_signer(racing_success) { SignPostJob.perform_now(post.id) }
    end

    post.reload
    assert_equal "draft", post.status
    assert_nil post.signed_event
  end

  # H15: reposts whose account has no signer are failed, not left hanging.
  def test_repost_without_signer_is_failed_instead_of_stranded
    post = build_post(unsigned_event: { "kind" => 1 })
    repost = build_repost(post: post, account: build_account(signer: false),
                          unsigned_event: { "kind" => 6 })

    without_broadcasts do
      with_signer(fake_event) { SignPostJob.perform_now(post.id) }
    end

    assert_equal "failed", repost.reload.status
    assert_equal "scheduled", post.reload.status
  end

  def test_repost_sign_timeout_does_not_stomp_a_concurrently_scheduled_repost
    post = build_post(unsigned_event: { "kind" => 1 })
    repost = build_repost(post: post, unsigned_event: { "kind" => 6 })

    responses = lambda do |account, _unsigned|
      if account.id == post.account_id
        fake_event
      else
        Repost.where(id: repost.id).update_all(status: Repost.statuses[:scheduled])
        nil
      end
    end

    without_broadcasts do
      with_signer(responses) { SignPostJob.perform_now(post.id) }
    end

    assert_equal "scheduled", repost.reload.status
  end

  def test_missing_post_is_discarded_rather_than_raising
    assert_nothing_raised { SignPostJob.perform_now(0) }
  end
end
