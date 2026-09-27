# frozen_string_literal: true

require_relative "../test_helper"

# Renders every posts / calendar / dashboard page (and the partials the jobs
# broadcast) once in each state, so a mistyped translation key fails here
# (raise_on_missing_translations is on in test) rather than in production.
class PostsRendersTest < ActionDispatch::IntegrationTest
  include NostrTestHelper
  include SessionHelper

  def setup
    @user = create_signed_in_user
    @account = paired_account("Author")
    @other = paired_account("Resharer")
  end

  def paired_account(name)
    @user.accounts.create!(
      pubkey_hex: SecureRandom.hex(32),
      display_name: name,
      signer_pubkey: SecureRandom.hex(32),
      signer_relay: "wss://relay.example.com",
      app_privkey: SecureRandom.hex(32),
      app_pubkey: SecureRandom.hex(32),
      write_relays: [ "wss://relay.example.com" ]
    )
  end

  def event
    { "id" => SecureRandom.hex(32), "pubkey" => @account.pubkey_hex, "kind" => 1, "content" => "hi",
      "created_at" => Time.current.to_i, "tags" => [], "sig" => SecureRandom.hex(64) }
  end

  def make_post(status, **attrs)
    @account.posts.create!({ content: "Hello #{status}", status: status, scheduled_at: 1.hour.from_now }.merge(attrs))
  end

  def test_dashboard_calendar_and_index
    make_post(:scheduled, signed_event: event)
    make_post(:awaiting_signature, unsigned_event: event)
    make_post(:failed, signed_event: event, publish_results: { "wss://a" => "timeout" })
    make_post(:published, signed_event: event, published_at: 1.hour.ago, scheduled_at: 2.hours.ago,
                          publish_results: { "wss://a" => "ok", "wss://b" => "timeout", "wss://c" => "rejected" })
    make_post(:published, signed_event: event, published_at: 1.hour.ago, scheduled_at: 2.hours.ago,
                          publish_results: { "wss://a" => "ok" })

    get dashboard_path
    assert_response :success
    assert_match(/held/, response.body)

    get calendar_path
    assert_response :success
    assert_match(/Previous month/, response.body)

    %w[short failed awaiting_signature scheduled published draft].each do |status|
      get posts_path(status: status)
      assert_response :success
    end
    get posts_path
    assert_response :success
    assert_match(/All posts/, response.body)
  end

  def test_empty_dashboard_and_index
    @user.accounts.destroy_all
    get dashboard_path
    assert_response :success
    get posts_path
    assert_response :success
    get new_post_path
    assert_response :success
  end

  def test_composer_pages
    get new_post_path
    assert_response :success
    get new_account_post_path(@account)
    assert_response :success
    assert_match(/Save &amp; Schedule/, response.body)

    draft = make_post(:draft, scheduled_at: nil)
    get edit_post_path(draft)
    assert_response :success
    get schedule_post_path(draft)
    assert_response :success
    assert_match(/Sign &amp; Schedule/, response.body)

    post account_posts_path(@account), params: { post: { content: "" } }
    assert_response :unprocessable_entity
    assert_match(/1 error prevented this post from being saved/, response.body)
  end

  def test_show_in_every_state
    draft = make_post(:draft, scheduled_at: nil)
    awaiting = make_post(:awaiting_signature, unsigned_event: event)
    Repost.create!(post: awaiting, account: @other, status: :awaiting_signature, scheduled_at: 2.hours.from_now)
    unsigned_failed = make_post(:failed, unsigned_event: event)
    scheduled = make_post(:scheduled, signed_event: event, event_id: SecureRandom.hex(32))
    due = make_post(:scheduled, signed_event: event)
    due.update_columns(scheduled_at: 1.minute.ago)
    publishing = make_post(:publishing, signed_event: event)
    publishing.update_columns(updated_at: 1.hour.ago)
    failed = make_post(:failed, signed_event: event, publish_results: { "wss://a" => "timeout" })
    short = make_post(:published, signed_event: event, event_id: SecureRandom.hex(32), published_at: Time.current,
                                  publish_results: { "wss://a" => "ok", "wss://b" => "timeout" })
    Repost.create!(post: short, account: @other, status: :published, scheduled_at: 1.hour.ago,
                   signed_event: event, publish_results: { "wss://a" => "ok" })
    full = make_post(:published, signed_event: event, published_at: Time.current, publish_results: { "wss://a" => "ok" })

    [ draft, awaiting, unsigned_failed, scheduled, due, publishing, failed, short, full ].each do |record|
      get post_path(record)
      assert_response :success, "show failed for #{record.status}"
    end

    get post_path(awaiting)
    assert_match(/Approve in Amber/, response.body)
    get post_path(publishing)
    assert_match(/Retry publishing/, response.body)
  end

  def test_broadcast_partials_render_in_the_users_language
    awaiting = make_post(:awaiting_signature, unsigned_event: event)
    html = ApplicationController.render(partial: "posts/signing_progress",
                                        locals: { post: awaiting, failed: true, error: nil })
    assert_match(/Your signer did not return a signature/, html)
  end

  def test_flash_and_schedule_errors
    draft = make_post(:draft, scheduled_at: nil)
    post sign_post_path(draft), params: { scheduled_at: "" }
    assert_response :unprocessable_entity
    assert_match(/Pick a date and time to publish this post/, response.body)

    delete discard_failed_posts_path
    follow_redirect!
    assert_response :success
  end

  def test_blossom_upload_errors
    post account_blossom_uploads_path(@account)
    assert_response :unprocessable_entity
    assert_equal "No file provided", response.parsed_body["error"]
  end
end
