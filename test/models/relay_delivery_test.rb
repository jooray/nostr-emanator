# frozen_string_literal: true

require "test_helper"

# Delivery is graded from publish_results, never from status.
#
# The regression this guards against is the one the whole console redesign was
# built around: a post that reached one relay out of six used to set status to
# `published`, which rendered as a green tick identical to a 6/6 delivery. If
# these ever go back to reading `status` alone, that lie comes back.
class RelayDeliveryTest < ActiveSupport::TestCase
  include NostrTestHelper

  def setup
    @user = User.create!(pubkey_hex: keypair.first, npub: "npub1test")
    @account = @user.accounts.create!(pubkey_hex: keypair.first)
  end

  def build(results, status: :published)
    @account.posts.create!(
      content: "x", status: status, scheduled_at: 1.hour.ago,
      published_at: (1.hour.ago if status == :published),
      publish_results: results
    )
  end

  def test_full_delivery_is_not_short
    post = build({ "wss://a" => "ok", "wss://b" => "ok" })

    assert_equal :all, post.delivery_grade
    assert_equal "2/2", post.delivery_tally
    refute_predicate post, :delivery_short?
  end

  def test_short_delivery_is_detected_even_though_status_says_published
    post = build({ "wss://a" => "ok", "wss://b" => "error: rate-limited" })

    assert_predicate post, :published?
    assert_equal :partial, post.delivery_grade
    assert_equal "1/2", post.delivery_tally
    assert_predicate post, :delivery_short?, "1 of 2 relays must not report as a clean delivery"
    assert_equal({ "wss://b" => "error: rate-limited" }, post.delivery_failures)
  end

  # An unsent post has no delivery to grade and must not read as a failure.
  def test_unpublished_post_is_not_short
    post = build({}, status: :scheduled)

    assert_equal :unknown, post.delivery_grade
    assert_nil post.delivery_tally
    refute_predicate post, :delivery_short?
  end

  def test_scheduled_post_with_no_results_is_not_short
    post = build(nil, status: :scheduled)

    assert_equal 0, post.delivery_total
    refute_predicate post, :delivery_short?
  end

  # A relay declining is ordinary on Nostr — every client over-publishes because
  # individual relays rate-limit and go down. Alarming on it trains the operator
  # to skip the alarm, so only "effectively not on the network" qualifies.
  def test_a_relay_declining_is_not_an_alarm
    post = build({ "wss://a" => "ok", "wss://b" => "ok", "wss://c" => "ok",
                   "wss://d" => "ok", "wss://e" => "ok", "wss://f" => "error" })

    assert_equal :partial, post.delivery_grade
    assert_predicate post, :delivery_short?, "5 of 6 did fall short of what was attempted"
    refute_predicate post, :delivery_alarming?, "but 5 of 6 is a normal publish, not an alarm"
  end

  def test_reaching_a_single_relay_out_of_many_is_an_alarm
    post = build({ "wss://a" => "ok", "wss://b" => "error", "wss://c" => "error",
                   "wss://d" => "error", "wss://e" => "error" })

    assert_equal :thin, post.delivery_grade
    assert_predicate post, :delivery_alarming?
  end

  # With only two relays on file, one accepting is half the network, not a
  # near-miss — the thin floor exists so that judgement scales with the attempt.
  def test_one_of_two_is_not_thin
    post = build({ "wss://a" => "ok", "wss://b" => "error" })

    assert_equal :partial, post.delivery_grade
    refute_predicate post, :delivery_alarming?
  end

  def test_reaching_nothing_is_an_alarm
    post = build({ "wss://a" => "timeout", "wss://b" => "rejected" })

    assert_equal :none, post.delivery_grade
    assert_predicate post, :delivery_alarming?
  end

  # The sentence a screen reader gets instead of the lamps.
  def test_delivery_sentence_states_the_tally
    post = build({ "wss://a" => "ok", "wss://b" => "error" })

    assert_match(/1 of 2/, ApplicationController.helpers.delivery_sentence(post))
  end

  # Reposts carry the same grading: they were the other half of the same lie.
  def test_reposts_grade_their_own_delivery
    post = build({ "wss://a" => "ok" })
    repost = post.reposts.create!(
      account: @account, status: :published, scheduled_at: 1.hour.ago,
      delay_minutes: 5, publish_results: { "wss://a" => "ok", "wss://b" => "timeout" }
    )

    assert_predicate repost, :delivery_short?
    assert_equal "1/2", repost.delivery_tally
  end
end
