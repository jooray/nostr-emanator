# frozen_string_literal: true

require_relative "../../test_helper"

class AccountApiTest < ActionDispatch::IntegrationTest
  include ApiTestHelper
  include ActiveJob::TestHelper

  def setup
    @user = create_api_user
    @account = create_signed_account(@user)
  end

  def test_accounts_list_with_counts
    @account.posts.create!(content: "a")
    api_get "/api/v1/accounts"

    assert_response :success
    account = json["accounts"].first
    assert_equal 1, account.dig("counts", "draft")
    assert account["has_signer"]
  end

  def test_update_personality_and_blossom_server
    api_patch "/api/v1/accounts/#{@account.id}", params: { account: { personality: "Dry wit" } }
    assert_response :success
    assert_equal "Dry wit", @account.reload.personality

    api_patch "/api/v1/accounts/#{@account.id}", params: { account: { blossom_server: "ftp://media.example" } }
    assert_response :unprocessable_entity
    assert json["error"].present?
  end

  def test_me_update_settings_and_media
    api_patch "/api/v1/me", params: { locale: "cs", timezone: "Europe/Bratislava", media: { max_edge: 1600, quality: 70, photo_format: "webp", compress: false, video_resolution: 720, video_quality: "small" } }

    assert_response :success
    assert_equal "cs", @user.reload.locale
    assert_equal "Europe/Bratislava", @user.timezone
    media = json.dig("user", "settings", "media")
    assert_equal({ "compress" => false, "max_edge" => 1600, "quality" => 70, "photo_format" => "webp",
                   "video_compress" => true, "video_resolution" => 720, "video_quality" => "small" }, media)
  end

  def test_sharing_settings_are_off_by_default_and_toggle_through_the_api
    api_get "/api/v1/me"
    %w[x facebook linkedin].each { |network| assert_equal false, json.dig("user", "settings", "#{network}_share") }

    api_patch "/api/v1/me", params: { x_share: true, facebook_share: true, linkedin_share: true }
    assert_response :success
    %w[x facebook linkedin].each do |network|
      assert_equal true, json.dig("user", "settings", "#{network}_share"), network
      assert @user.reload.public_send("#{network}_share?"), network
    end

    api_patch "/api/v1/me", params: { x_share: false }
    @user.reload
    refute @user.x_share?
    assert @user.facebook_share?
    assert @user.linkedin_share?
  end

  def test_invalid_media_values_are_ignored
    api_patch "/api/v1/me", params: { media: { max_edge: 999, quality: 5, photo_format: "gif" } }
    assert_equal MediaPreferences::DEFAULTS, json.dig("user", "settings", "media")
  end

  def test_pairing_a_new_account
    override(Nip46SupervisorJob, :ensure_running, nil) { api_post "/api/v1/pairings" }
    assert_response :created
    session_id = json["session_id"]

    api_get "/api/v1/pairings/#{session_id}"
    assert_equal "pending", json["status"]

    pubkey = SecureRandom.hex(32)
    NostrAuthSession.find_by!(session_id: session_id)
                    .update!(authenticated_pubkey: SecureRandom.hex(32), authenticated_user_pubkey: pubkey)

    api_get "/api/v1/pairings/#{session_id}"
    assert_equal "paired", json["status"]
    assert_equal pubkey, json.dig("account", "pubkey_hex")
    assert @user.accounts.exists?(pubkey_hex: pubkey)
  end

  def test_re_pair_refuses_a_different_identity
    override(Nip46SupervisorJob, :ensure_running, nil) { api_post "/api/v1/pairings", params: { account_id: @account.id } }
    session_id = json["session_id"]
    NostrAuthSession.find_by!(session_id: session_id)
                    .update!(authenticated_pubkey: SecureRandom.hex(32), authenticated_user_pubkey: SecureRandom.hex(32))

    api_get "/api/v1/pairings/#{session_id}", params: { account_id: @account.id }
    assert_equal "failed", json["status"]
    assert_match "different Nostr identity", json["error"]
  end

  def test_devices_and_mcp_tokens
    api_post "/api/v1/mcp_tokens", params: { name: "Agent", expires_in_days: 30 }
    assert_response :created
    assert_match(/\Aemn_/, json["token"])

    api_get "/api/v1/mcp_tokens"
    assert_equal [ "Agent" ], json["tokens"].map { |t| t["name"] }

    api_get "/api/v1/devices"
    assert_equal [ true ], json["devices"].map { |d| d["current"] }
  end
end
