# frozen_string_literal: true

require_relative "../test_helper"

# Saving a post used to land on its read-only page, whose only real action was
# a Schedule button. The composer already showed the text, so that page was a
# confirmation step with nothing to confirm: save now lands on scheduling, and
# the edit/delete it offered live under the schedule page's preview instead.
class SaveGoesStraightToScheduleTest < ActionDispatch::IntegrationTest
  include NostrTestHelper
  include SessionHelper

  def setup
    @user = create_signed_in_user
    @account = @user.accounts.create!(
      pubkey_hex: SecureRandom.hex(32),
      display_name: "Author",
      signer_pubkey: SecureRandom.hex(32),
      app_privkey: SecureRandom.hex(32),
      app_pubkey: SecureRandom.hex(32)
    )
  end

  def test_creating_a_post_opens_the_schedule_page
    post account_posts_path(@account), params: { post: { content: "hello" } }

    created = @account.posts.last
    assert_redirected_to schedule_post_path(created)
  end

  def test_editing_a_draft_returns_to_the_schedule_page
    draft = @account.posts.create!(content: "old", status: :draft)

    patch post_path(draft), params: { post: { content: "new" } }

    assert_redirected_to schedule_post_path(draft)
  end

  def test_schedule_page_offers_edit_and_delete
    draft = @account.posts.create!(content: "hello", status: :draft)

    get schedule_post_path(draft)

    assert_response :success
    assert_select "a[href=?]", edit_post_path(draft)
    assert_select "form[action=?] input[name=_method][value=delete]", post_path(draft)
  end
end
