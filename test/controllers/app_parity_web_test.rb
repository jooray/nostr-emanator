# frozen_string_literal: true

require_relative "../test_helper"

# The web side of the Android app: the pages that exist for it, and the
# settings both clients share.
class AppParityWebTest < ActionDispatch::IntegrationTest
  include NostrTestHelper
  include SessionHelper
  include ApiTestHelper

  def test_public_pages_render_without_a_session
    get billing_return_path
    assert_response :success
    assert_select "a[href='emanator://billing']"
    # BTCPay lands here by itself: the page hands over to the app at once, under the CSP nonce.
    nonce = response.headers["Content-Security-Policy"][/'nonce-([^']+)'/, 1]
    assert_select "script[nonce='#{nonce}']", text: /location\.replace\("emanator:\/\/billing"\)/

    get android_app_path
    assert_response :success
  end

  def test_signed_in_pages_carry_the_android_app_banner_once_released
    create_signed_in_user

    override(AndroidApp, :released?, false) do
      get dashboard_path
      assert_select "[data-controller='android-app-banner']", count: 0
    end

    override(AndroidApp, :released?, true) do
      get dashboard_path
      assert_select "[data-controller='android-app-banner'][hidden] a[href='#{android_app_path}']"

      get android_app_path
      assert_select "[data-controller='android-app-banner']", count: 0
    end
  end

  def test_the_pwa_manifest_is_valid_json_with_the_app_icons
    get pwa_manifest_path(format: :json)
    assert_response :success
    manifest = JSON.parse(response.body)
    assert_equal I18n.t("pwa.manifest.description"), manifest["description"]
    assert_includes manifest["icons"].map { it["purpose"] }, "maskable"
    manifest["icons"].each { assert Rails.public_path.join(it["src"].delete_prefix("/")).exist?, it["src"] }
  end

  def test_media_settings_are_saved_and_reach_the_composer
    user = create_signed_in_user
    account = user.accounts.create!(pubkey_hex: SecureRandom.hex(32), display_name: "A")

    patch user_path, params: { media: { compress: "1", max_edge: "1280", quality: "75", photo_format: "webp" } }
    assert_redirected_to edit_user_path(anchor: "media-settings")
    assert_equal 1280, MediaPreferences.for(user.reload)["max_edge"]

    get new_account_post_path(account)
    assert_select "[data-blossom-upload-media-value*='\"photo_format\":\"webp\"']"

    patch user_path, params: { media: { video_compress: "0", video_resolution: "720", video_quality: "high" } }
    prefs = MediaPreferences.for(user.reload)
    assert_equal [ false, 720, "high" ], prefs.values_at("video_compress", "video_resolution", "video_quality")
    assert_equal 1280, prefs["max_edge"], "a video change keeps the photo settings"

    patch user_path, params: { media: { video_resolution: "999", video_quality: "huge" } }
    assert_equal [ 720, "high" ], MediaPreferences.for(user.reload).values_at("video_resolution", "video_quality")

    get new_account_post_path(account)
    assert_select "[data-blossom-upload-video-compress-url-value*='video_compress']"
  end

  def test_settings_list_devices_apart_from_mcp_tokens_and_sign_one_out
    user = create_signed_in_user
    device = ApiToken.issue_device!(user, name: "Pixel 9")
    ApiToken.generate(user, name: "Claude agent")

    get edit_user_path
    assert_select "#devices [data-device-id='#{device.id}']", text: /Pixel 9/
    assert_select "#api-tokens", text: /Claude agent/
    assert_select "#api-tokens", text: /Pixel 9/, count: 0

    delete api_token_path(device)
    assert_redirected_to edit_user_path(anchor: "devices")
    assert_nil ApiToken.find_by(id: device.id)
  end
end
