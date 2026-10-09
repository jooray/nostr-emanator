# frozen_string_literal: true

require_relative "../../test_helper"

# Logging the Android app in through the same NIP-46 sessions as the web, and
# the boundary between device tokens and MCP tokens.
class AuthApiTest < ActionDispatch::IntegrationTest
  include ApiTestHelper

  def without_supervisor(&block) = override(Nip46SupervisorJob, :ensure_running, nil, &block)

  def test_meta_is_public_and_describes_the_server
    get "/api/v1/meta"

    assert_response :success
    assert_equal 1, json["api_version"]
    assert_includes json["locales"], "sk"
    assert json["android"].key?("min_version_code")
  end

  def test_nostrconnect_then_poll_logs_the_app_in_and_imports_the_account
    without_supervisor { post "/api/v1/auth/nostrconnect", as: :json }
    assert_response :success
    assert_match %r{\Anostrconnect://}, json["uri"]
    session_id = json["session_id"]
    refute_includes json["uri"], session_id, "the poll credential must not be in the QR/URI"

    post "/api/v1/auth/poll", params: { session_id: session_id }, as: :json
    assert_equal "pending", json["status"]

    signer = SecureRandom.hex(32)
    user_pubkey = SecureRandom.hex(32)
    NostrAuthSession.find_by!(session_id: session_id)
                    .update!(authenticated_pubkey: signer, authenticated_user_pubkey: user_pubkey)

    post "/api/v1/auth/poll", params: { session_id: session_id, device_name: "Pixel", client_version: "3" }, as: :json
    assert_equal "authenticated", json["status"]
    assert_match(/\Aemd_/, json["token"])

    user = User.find_by!(pubkey_hex: user_pubkey)
    account = user.accounts.find_by!(pubkey_hex: user_pubkey)
    assert_equal signer, account.signer_pubkey, "the login's signer pairs the primary account"
    assert_equal "Pixel", user.api_tokens.device.last.name

    get "/api/v1/me", headers: api_headers(json["token"])
    assert_response :success
    assert_equal user.npub, json.dig("user", "npub")

    post "/api/v1/auth/poll", params: { session_id: session_id }, as: :json
    assert_equal "expired", json["status"], "a session logs in once"
  end

  def test_unknown_session_is_expired
    post "/api/v1/auth/poll", params: { session_id: SecureRandom.uuid }, as: :json
    assert_equal "expired", json["status"]
  end

  def test_bad_bunker_link_is_refused
    post "/api/v1/auth/bunker", params: { bunker_uri: "https://example.com" }, as: :json
    assert_response :unprocessable_entity
    assert_equal "invalid_link", json["code"]
  end

  def test_an_mcp_token_cannot_reach_the_app_api
    user = create_api_user
    mcp = ApiToken.generate(user, name: "agent")

    get "/api/v1/me", headers: api_headers(mcp.plain_token)
    assert_response :unauthorized
  end

  def test_a_device_token_cannot_reach_mcp
    create_api_user
    post "/mcp", params: { jsonrpc: "2.0", id: 1, method: "ping" }.to_json,
                 headers: { "Authorization" => "Bearer #{@device_token.plain_token}", "Content-Type" => "application/json" }
    assert_response :unauthorized
  end

  def test_an_old_app_build_is_told_to_update
    create_api_user
    override(AndroidApp, :min_version_code, 5) do
      get "/api/v1/me", headers: api_headers(client: "android/4")
    end

    assert_response :upgrade_required
    assert_equal "upgrade_required", json["code"]
    assert json.key?("download_url")
  end

  def test_logout_revokes_only_this_device
    user = create_api_user
    other = ApiToken.issue_device!(user, name: "Tablet")

    delete "/api/v1/session", headers: api_headers
    assert_response :no_content

    get "/api/v1/me", headers: api_headers
    assert_response :unauthorized
    get "/api/v1/me", headers: api_headers(other.plain_token)
    assert_response :success
  end

  def test_use_slides_the_device_expiry
    create_api_user
    @device_token.update_columns(expires_at: 2.days.from_now, last_used_at: 1.hour.ago)

    get "/api/v1/me", headers: api_headers
    assert_operator @device_token.reload.expires_at, :>, 170.days.from_now
  end

  def test_expired_device_token_is_refused
    create_api_user
    @device_token.update_columns(expires_at: 1.minute.ago)

    get "/api/v1/me", headers: api_headers
    assert_response :unauthorized
  end
end
