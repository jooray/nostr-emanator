# frozen_string_literal: true

require_relative "../test_helper"

class PostTest < ActiveSupport::TestCase
  def test_only_kind_one_is_schedulable_as_a_post
    post = Post.new(content: "hello", event_kind: 1)
    post.validate
    assert_empty post.errors[:event_kind]

    post.event_kind = 30_023
    refute post.valid?
    assert_includes post.errors[:event_kind], "is not included in the list"
  end

  def test_scheduled_posts_require_a_publish_time
    account = Account.create!(
      user: User.create!(npub: "npub_post_test", pubkey_hex: SecureRandom.hex(32)),
      pubkey_hex: SecureRandom.hex(32)
    )

    post = account.posts.create!(content: "hi", event_kind: 1, status: :draft)
    assert post.valid?

    # H8: a scheduled post without scheduled_at would never be enqueued.
    post.status = :scheduled
    refute post.valid?
    assert_includes post.errors[:scheduled_at], "can't be blank"

    post.scheduled_at = 1.hour.from_now
    assert post.valid?
  end

  # C4: a post abandoned mid-publish must be recoverable from the UI.
  def test_publishing_posts_can_be_cancelled_and_retried
    post = Post.new(content: "hi", event_kind: 1, status: :publishing, signed_event: { "id" => "abc" })

    assert post.can_cancel?
    assert post.can_retry_publish?
  end
end
