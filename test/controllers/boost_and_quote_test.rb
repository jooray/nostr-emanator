# frozen_string_literal: true

require_relative "../test_helper"

# "Boost as…" and "Quote as…" on the post list: another account reposts a
# published note at once, or opens the composer with the note quoted.
class BoostAndQuoteTest < ActionDispatch::IntegrationTest
  include NostrTestHelper
  include SessionHelper
  include ActiveJob::TestHelper

  def setup
    @user = create_signed_in_user
    @author = paired_account("Author")
    @booster = paired_account("Booster")
    event_id = "ab" * 32
    @post = @author.posts.create!(
      content: "Hello from the author", status: :published, published_at: 1.hour.ago, event_id: event_id,
      signed_event: { "id" => event_id, "pubkey" => @author.pubkey_hex, "kind" => 1, "content" => "Hello from the author",
                      "tags" => [], "created_at" => 1.hour.ago.to_i, "sig" => "cd" * 64 }
    )
  end

  def test_the_list_offers_both_menus_for_a_published_note
    get posts_path
    assert_response :success
    assert_match "Boost as…", response.body
    assert_match "Quote as…", response.body
    assert_match boost_post_path(@post), response.body
  end

  def test_boost_creates_a_repost_that_publishes_now
    assert_enqueued_with(job: PublishNowRepostJob) do
      post boost_post_path(@post), params: { account_id: @booster.id }
    end
    repost = @post.reposts.find_by!(account: @booster)
    assert repost.awaiting_signature?
    assert_equal 6, repost.unsigned_event["kind"]
    assert_equal @post.event_id, repost.unsigned_event["tags"].first[1]
    assert_match "Boosting as Booster", flash[:notice]
  end

  def test_a_second_boost_by_the_same_account_is_refused
    post boost_post_path(@post), params: { account_id: @booster.id }
    post boost_post_path(@post), params: { account_id: @booster.id }
    assert_match "already boosted", flash[:alert]
    assert_equal 1, @post.reposts.count
  end

  def test_the_author_cannot_boost_its_own_note
    post boost_post_path(@post), params: { account_id: @author.id }
    assert_equal I18n.t("posts.boost.own_note"), flash[:alert]
    assert_empty @post.reposts
  end

  def test_an_unpublished_note_cannot_be_boosted
    @post.update!(status: :scheduled, scheduled_at: 1.hour.from_now)
    post boost_post_path(@post), params: { account_id: @booster.id }
    assert_equal I18n.t("posts.boost.not_published"), flash[:alert]
  end

  def test_quote_opens_the_composer_with_the_reference
    get new_account_post_path(@booster, quote: @post.id)
    assert_response :success
    assert_match @post.nostr_reference, response.body
  end

  def test_quote_ignores_a_note_of_another_user
    stranger = User.create!(pubkey_hex: SecureRandom.hex(32), npub: "npub_stranger")
    theirs = stranger.accounts.create!(pubkey_hex: SecureRandom.hex(32))
    note = theirs.posts.create!(content: "x", status: :published, event_id: "ef" * 32)

    get new_account_post_path(@booster, quote: note.id)
    assert_response :success
    assert_no_match note.nostr_reference, response.body
  end

  private

  def paired_account(name)
    @user.accounts.create!(
      pubkey_hex: SecureRandom.hex(32), display_name: name,
      signer_pubkey: SecureRandom.hex(32), app_privkey: SecureRandom.hex(32), app_pubkey: SecureRandom.hex(32)
    )
  end
end
