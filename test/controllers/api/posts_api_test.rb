# frozen_string_literal: true

require_relative "../../test_helper"

class PostsApiTest < ActionDispatch::IntegrationTest
  include ApiTestHelper
  include ActiveJob::TestHelper

  def setup
    @user = create_api_user
    @account = create_signed_account(@user)
  end

  def create_draft(content = "Hello Nostr")
    api_post "/api/v1/posts", params: { account_id: @account.id, post: { content: content } }
    assert_response :created
    json["post"]
  end

  def test_draft_edit_schedule_cancel
    draft = create_draft
    assert_equal "draft", draft["status"]
    assert draft.dig("can", "schedule")

    api_patch "/api/v1/posts/#{draft['id']}", params: { post: { content: "Edited" } }
    assert_response :success
    assert_equal "Edited", json.dig("post", "content")
    assert_equal "Hello Nostr", json.dig("post", "version_history", 0, "content")

    api_get "/api/v1/posts/#{draft['id']}/schedule_options"
    assert_response :success
    assert json["suggested_at"].present?

    other = create_signed_account(@user, display_name: "Other")
    at = 2.days.from_now.utc.iso8601
    assert_enqueued_with(job: SignPostJob) do
      api_post "/api/v1/posts/#{draft['id']}/schedule", params: { scheduled_at: at, repost_account_ids: [ other.id ] }
    end
    assert_response :success
    assert_equal "awaiting_signature", json.dig("post", "status")
    assert_equal [ other.id ], json.dig("post", "reposts").map { |r| r["account_id"] }
    assert_match "Signing", json["message"]

    api_post "/api/v1/posts/#{draft['id']}/cancel"
    assert_response :success
    assert_equal "draft", json.dig("post", "status")
    assert_empty json.dig("post", "reposts")
  end

  def test_schedule_in_the_past_is_refused_with_the_web_message
    draft = create_draft
    api_post "/api/v1/posts/#{draft['id']}/schedule", params: { scheduled_at: 1.hour.ago.utc.iso8601 }

    assert_response :unprocessable_entity
    assert_equal I18n.t("posts.flash.time_in_past"), json["error"]
  end

  def test_schedule_answers_in_the_users_language
    @user.update!(settings: { "locale" => "sk" })
    draft = create_draft
    api_post "/api/v1/posts/#{draft['id']}/schedule", params: { scheduled_at: 1.hour.ago.utc.iso8601 }

    assert_equal I18n.t("posts.flash.time_in_past", locale: :sk), json["error"]
  end

  def test_repost_without_signer_is_failed_not_stranded
    draft = create_draft
    unsigned = @user.accounts.create!(pubkey_hex: SecureRandom.hex(32), display_name: "No signer")

    api_post "/api/v1/posts/#{draft['id']}/schedule", params: { scheduled_at: 1.day.from_now.utc.iso8601, repost_account_ids: [ unsigned.id ] }

    repost = json.dig("post", "reposts").first
    assert_equal "failed", repost["status"]
  end

  def test_reply_signs_at_once
    assert_enqueued_with(job: SignPostJob) do
      api_post "/api/v1/posts", params: { account_id: @account.id, post: {
        content: "Agreed", is_reply: true, reply_to_event_id: SecureRandom.hex(32), reply_to_pubkey: SecureRandom.hex(32)
      } }
    end
    assert_response :created
    assert_equal "awaiting_signature", json.dig("post", "status")
  end

  def test_list_filters_and_merges_failed_reposts
    post_record = @account.posts.create!(content: "x", status: :failed)
    other = create_signed_account(@user)
    published = @account.posts.create!(content: "y", status: :published, published_at: Time.current)
    published.reposts.create!(account: other, status: :failed, scheduled_at: Time.current)

    api_get "/api/v1/posts", params: { status: "failed" }
    assert_response :success
    assert_equal %w[post repost].sort, json["items"].map { |i| i["type"] }.sort
    assert_equal 2, json["failed_here"]

    api_delete "/api/v1/failed_posts"
    assert_equal 2, json["discarded"]
    assert_nil Post.find_by(id: post_record.id)
  end

  def test_another_users_post_is_not_found
    stranger = create_api_user
    foreign = create_signed_account(stranger).posts.create!(content: "theirs")
    @device_token = ApiToken.issue_device!(@user, name: "me")

    api_get "/api/v1/posts/#{foreign.id}"
    assert_response :not_found
  end

  def test_dashboard_lists_sections
    @account.posts.create!(content: "wait", status: :awaiting_signature, scheduled_at: 1.day.from_now)
    api_get "/api/v1/dashboard"

    assert_response :success
    assert_equal 1, json["waiting"].size
    assert_equal 1, json.dig("summary", "waiting")
  end

  def test_calendar_returns_scheduled_items_in_span
    @account.posts.create!(content: "soon", status: :scheduled, scheduled_at: 3.days.from_now)
    api_get "/api/v1/calendar", params: { from: Time.current.utc.iso8601, to: 10.days.from_now.utc.iso8601 }

    assert_response :success
    assert_equal [ "soon" ], json["items"].map { |i| i["content"] }
  end

  def test_content_references_are_resolved
    target = @user.accounts.create!(pubkey_hex: SecureRandom.hex(32), display_name: "Satoshi")
    npub = Nostr::KeyConverter.hex_to_npub(target.pubkey_hex)
    draft = create_draft("gm nostr:#{npub}")

    api_get "/api/v1/posts/#{draft['id']}"
    ref = json.dig("post", "references").first
    assert_equal "profile", ref["type"]
    assert_equal "@Satoshi", ref["label"]
    assert_equal "nostr:#{npub}", ref["match"]
  end
end
