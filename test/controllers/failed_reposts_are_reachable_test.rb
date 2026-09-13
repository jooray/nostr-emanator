# frozen_string_literal: true

require_relative "../test_helper"

# The rail said "2 never went out". Clicking it produced "No posts match this
# filter." Both queries were right about themselves: station_status counts
# Post.failed + Repost.failed, and every list the reading pointed at queried
# Post alone. Both failures were reposts, so the app counted two real failures
# and then offered no surface anywhere that could show them.
#
# The rule this pins: a station reading and the list it links to count the same
# set. A reading the operator cannot act on is worse than no reading — it is an
# alarm with nothing under it, which is how an alarm stops meaning anything.
class FailedRepostsAreReachableTest < ActionDispatch::IntegrationTest
  include NostrTestHelper
  include SessionHelper

  def setup
    @user = create_signed_in_user
    @author = paired_account("Author")
    @resharer = paired_account("Resharer")
  end

  def test_a_failed_repost_appears_in_the_never_went_out_list
    repost = failed_repost

    get posts_path(status: "failed")

    assert_response :success
    assert_no_match(/No posts match this filter/, response.body)
    assert_match(/Repost of this note/, response.body)
    assert_match(/Resharer/i, response.body)
    assert_match(/#{repost.post.content}/, response.body)
  end

  def test_the_rail_reading_and_the_list_agree
    2.times { failed_repost }

    get dashboard_path
    reading = station_reading_count(response.body)

    get posts_path(status: "failed")
    rows = response.body.scan(/Repost of this note/).size

    assert_equal 2, reading, "the rail should count both failed reposts"
    assert_equal reading, rows, "the list must show exactly what the reading counts"
  end

  def test_the_dashboard_never_went_out_section_lists_failed_reposts
    failed_repost

    get dashboard_path

    assert_response :success
    assert_match(/Never went out/i, response.body)
    assert_match(/Repost of this note/, response.body)
  end

  def test_a_failed_repost_offers_its_own_retry
    repost = failed_repost

    get posts_path(status: "failed")

    assert_response :success
    # Its own signing path — retrying the note would not resend the repost.
    assert_match(%r{/posts/#{repost.post.id}/reposts/#{repost.id}/retry_sign}, response.body)
  end

  def test_discard_all_clears_failed_reposts_too
    2.times { failed_repost }

    delete discard_failed_posts_path

    assert_equal 0, Repost.where(status: :failed).count,
                 "Discard all must clear the reposts it counted, or the alarm stays lit"
  end

  def test_a_repost_awaiting_a_signature_is_reachable_from_its_reading
    repost = awaiting_repost

    get posts_path(status: "awaiting_signature")

    assert_response :success
    assert_match(/Repost of this note/, response.body)
    assert_match(%r{/posts/#{repost.post.id}}, response.body)
  end

  def test_a_failed_post_and_a_failed_repost_list_together
    post = @author.posts.create!(content: "note that failed", status: "failed", scheduled_at: 2.days.ago)
    failed_repost

    get posts_path(status: "failed")

    assert_response :success
    assert_match(/#{post.content}/, response.body)
    assert_match(/Repost of this note/, response.body)
  end

  # A record that failed before reaching any relay carries {"error" => why},
  # which the relay formatter rendered as "error Signing was never completed…".
  def test_a_signing_failure_reads_as_a_sentence_not_a_relay_line
    repost = failed_repost
    repost.update!(publish_results: { "error" => "Signing was never completed. Check your signer app is paired." })

    get posts_path(status: "failed")

    assert_response :success
    assert_match(/Signing was never completed/, response.body)
    assert_no_match(/error Signing was never completed/, response.body)
  end

  def test_a_relay_failure_still_names_the_relay
    repost = failed_repost
    repost.update!(publish_results: { "wss://relay.damus.io" => "rate-limited" })

    get posts_path(status: "failed")

    assert_response :success
    assert_match(/relay\.damus\.io rate-limited/, response.body)
  end

  private

  def station_reading_count(body)
    body[/(\d+)\s+never went out/i, 1].to_i
  end

  def failed_repost
    post = @author.posts.create!(content: "note #{SecureRandom.hex(3)}", status: "published",
                                 scheduled_at: 2.days.ago, published_at: 2.days.ago)
    Repost.create!(post: post, account: @resharer, status: "failed", scheduled_at: 2.days.ago)
  end

  def awaiting_repost
    post = @author.posts.create!(content: "note #{SecureRandom.hex(3)}", status: "scheduled",
                                 scheduled_at: 2.days.from_now)
    Repost.create!(post: post, account: @resharer, status: "awaiting_signature", scheduled_at: 2.days.from_now)
  end

  def paired_account(name)
    @user.accounts.create!(
      pubkey_hex: SecureRandom.hex(32),
      display_name: name,
      signer_pubkey: SecureRandom.hex(32),
      app_privkey: SecureRandom.hex(32),
      app_pubkey: SecureRandom.hex(32)
    )
  end
end
