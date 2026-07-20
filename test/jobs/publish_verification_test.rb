# frozen_string_literal: true

require_relative "job_test_helper"

# M4: a stored signed event is re-verified against the account's pubkey right
# before publishing, so a tampered or mixed-up row never reaches the relays.
class PublishVerificationTest < ActiveSupport::TestCase
  include JobTestHelper

  def test_post_signed_by_another_key_is_not_published
    post = build_post(status: :scheduled, scheduled_at: 1.minute.ago, signed_event: foreign_event)

    published = false
    without_broadcasts do
      with_publisher(->(_relays) { published = true; {} }) { PublishPostJob.perform_now(post.id) }
    end

    refute published, "an event not signed by the account key must not be published"
    assert_equal "failed", post.reload.status
  end

  def test_tampered_post_event_is_not_published
    event = fake_event
    post = build_post(status: :scheduled, scheduled_at: 1.minute.ago, signed_event: event.merge("content" => "rewritten"))

    published = false
    without_broadcasts do
      with_publisher(->(_relays) { published = true; {} }) { PublishPostJob.perform_now(post.id) }
    end

    refute published, "a mutated event body must not be published"
    assert_equal "failed", post.reload.status
  end
end
