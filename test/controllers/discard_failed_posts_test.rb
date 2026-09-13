# frozen_string_literal: true

require "test_helper"

# The first version of this shipped broken: the route was DELETE /posts/failed,
# which the shallow `resources :posts` already claimed as posts#destroy with
# id="failed". It raised RecordNotFound, Turbo swallowed the 404, and the button
# silently did nothing. These tests pin the route as well as the behaviour.
class DiscardFailedPostsTest < ActionDispatch::IntegrationTest
  include SessionHelper
  include NostrTestHelper

  def setup
    @user = create_signed_in_user(display_name: "Tester")
    @account = @user.accounts.create!(pubkey_hex: keypair.first, display_name: "Ember")
    @other = @user.accounts.create!(pubkey_hex: keypair.first, display_name: "Other")
  end

  def failed_post(account = @account)
    account.posts.create!(content: "never went out", status: :failed, scheduled_at: 200.days.ago)
  end

  def test_route_resolves_to_the_bulk_action_not_to_destroy
    assert_equal({ controller: "posts", action: "discard_failed" },
                 Rails.application.routes.recognize_path("/failed_posts", method: :delete))
  end

  def test_discards_every_failed_post
    3.times { failed_post }
    kept = @account.posts.create!(content: "still scheduled", status: :scheduled, scheduled_at: 1.day.from_now)

    assert_difference "Post.count", -3 do
      delete discard_failed_posts_path
    end

    assert_redirected_to dashboard_path
    assert Post.exists?(kept.id), "a scheduled post must not be swept up"
  end

  def test_scopes_to_the_account_filter
    2.times { failed_post(@account) }
    theirs = failed_post(@other)

    assert_difference "Post.count", -2 do
      delete discard_failed_posts_path(account: @account.id)
    end

    assert Post.exists?(theirs.id), "another identity's failures must survive a filtered discard"
  end

  # Nothing here may reach across logins.
  def test_never_touches_another_users_posts
    stranger = User.create!(pubkey_hex: keypair.first, npub: "npub1stranger")
    their_account = stranger.accounts.create!(pubkey_hex: keypair.first)
    theirs = their_account.posts.create!(content: "not yours", status: :failed, scheduled_at: 1.day.ago)

    delete discard_failed_posts_path

    assert Post.exists?(theirs.id)
  end
end
