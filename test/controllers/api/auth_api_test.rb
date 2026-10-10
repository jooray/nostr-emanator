# frozen_string_literal: true

require_relative "../../test_helper"

# Logging the Android app in through the same NIP-46 sessions as the web, and
# the boundary between device tokens and MCP tokens.
class AuthApiTest < ActionDispatch::IntegrationTest
  include ApiTestHelper
  include NostrTestHelper
  include CacheHelper

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
    poll_token = json["poll_token"]
    refute_includes json["uri"], session_id, "the poll credential must not be in the QR/URI"
    refute_includes json["uri"], poll_token

    post "/api/v1/auth/poll", params: { session_id: session_id, poll_token: poll_token }, as: :json
    assert_equal "pending", json["status"]

    signer = SecureRandom.hex(32)
    user_pubkey = SecureRandom.hex(32)
    NostrAuthSession.find_by!(session_id: session_id)
                    .update!(authenticated_pubkey: signer, authenticated_user_pubkey: user_pubkey)

    post "/api/v1/auth/poll", params: { session_id: session_id, poll_token: poll_token, device_name: "Pixel", client_version: "3" }, as: :json
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

  def test_poll_needs_the_poll_token_except_from_builds_that_predate_it
    without_supervisor { post "/api/v1/auth/nostrconnect", as: :json }
    session_id = json["session_id"]

    post "/api/v1/auth/poll", params: { session_id: session_id }, as: :json
    assert_response :not_found

    post "/api/v1/auth/poll", params: { session_id: session_id, poll_token: "0" * 64 }, as: :json
    assert_response :not_found

    post "/api/v1/auth/poll", params: { session_id: session_id }, headers: { "X-Emanator-Client" => "android/1" }, as: :json
    assert_equal "pending", json["status"]

    post "/api/v1/auth/poll", params: { session_id: session_id }, headers: { "X-Emanator-Client" => "android/2" }, as: :json
    assert_response :not_found
  end

  def test_a_signer_on_the_phone_signs_the_challenge_for_a_token
    pubkey, privkey = keypair
    post "/api/v1/auth/challenge", as: :json
    assert_response :success
    challenge = json["challenge"]
    assert_equal "emanator.cypherpunk.today", json["domain"]

    event = signed_event(privkey: privkey, pubkey: pubkey, kind: 22_242, content: "",
                         tags: [ [ "relay", "" ], [ "challenge", challenge ], [ "domain", json["domain"] ] ])
    post "/api/v1/auth/token", params: { signed_event: event, device_name: "Fold" }, as: :json

    assert_response :success
    assert_match(/\Aemd_/, json["token"])
    user = User.find_by!(pubkey_hex: pubkey)
    assert user.accounts.exists?(pubkey_hex: pubkey), "the login identity becomes the first account"
    assert_equal "Fold", user.api_tokens.device.last.name

    post "/api/v1/auth/token", params: { signed_event: event }, as: :json
    assert_response :unauthorized, "a challenge works once"
  end

  def test_a_proof_for_another_domain_or_challenge_is_refused
    pubkey, privkey = keypair
    post "/api/v1/auth/challenge", as: :json
    challenge = json["challenge"]
    wrong_domain = signed_event(privkey: privkey, pubkey: pubkey, kind: 22_242, content: "",
                                tags: [ [ "challenge", challenge ], [ "domain", "evil.example" ] ])
    post "/api/v1/auth/token", params: { signed_event: wrong_domain }, as: :json
    assert_response :unauthorized
    assert_equal "auth_failed", json["code"]

    post "/api/v1/auth/token", params: { signed_event: wrong_domain.merge("tags" => [ [ "challenge", challenge ], [ "domain", "emanator.cypherpunk.today" ] ]) }, as: :json
    assert_response :unauthorized, "the challenge was spent by the failed attempt, and the id no longer matches"

    unknown = signed_event(privkey: privkey, pubkey: pubkey, kind: 22_242, content: "",
                           tags: [ [ "challenge", SecureRandom.hex(32) ], [ "domain", "emanator.cypherpunk.today" ] ])
    post "/api/v1/auth/token", params: { signed_event: unknown }, as: :json
    assert_response :unauthorized
    refute User.exists?(pubkey_hex: pubkey)
  end

  def nip98_proof(privkey, pubkey, challenge, url:, method: "POST")
    signed_event(privkey: privkey, pubkey: pubkey, kind: 27_235, content: "",
                 tags: [ [ "u", url ], [ "method", method ], [ "challenge", challenge ] ])
  end

  def test_a_nip98_proof_for_the_token_endpoint_signs_the_app_in
    pubkey, privkey = keypair
    post "/api/v1/auth/challenge", as: :json
    token_url = json["token_url"]
    assert_equal "http://www.example.com/api/v1/auth/token", token_url

    # Scheme differences are ignored (TLS ends at nginx); host and path are not.
    proof = nip98_proof(privkey, pubkey, json["challenge"], url: token_url.sub("http://", "https://"), method: "post")
    post "/api/v1/auth/token", params: { signed_event: proof.to_json, device_name: "Fold" }, as: :json

    assert_response :success
    assert_match(/\Aemd_/, json["token"])
    assert User.exists?(pubkey_hex: pubkey)
  end

  def test_a_nip98_proof_naming_anything_else_is_refused
    pubkey, privkey = keypair
    {
      "another endpoint" => { url: "http://www.example.com/api/v1/auth/poll" },
      "another host" => { url: "http://evil.example/api/v1/auth/token" },
      "a query string" => { url: "http://www.example.com/api/v1/auth/token?x=1" },
      "another method" => { url: "http://www.example.com/api/v1/auth/token", method: "GET" }
    }.each do |what, options|
      post "/api/v1/auth/challenge", as: :json
      post "/api/v1/auth/token", params: { signed_event: nip98_proof(privkey, pubkey, json["challenge"], **options) }, as: :json
      assert_response :unauthorized, what
    end
    refute User.exists?(pubkey_hex: pubkey)
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
