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
end
