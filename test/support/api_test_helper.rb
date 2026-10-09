# frozen_string_literal: true

# A user signed in to /api/v1 with a device token, as the Android app would be.
module ApiTestHelper
  def create_api_user(**attrs)
    pubkey = SecureRandom.hex(32)
    user = User.create!({ pubkey_hex: pubkey, npub: Nostr::KeyConverter.hex_to_npub(pubkey), display_name: "Tester" }.merge(attrs))
    @device_token = ApiToken.issue_device!(user, name: "Test phone", client_version: "1")
    user
  end

  def api_headers(token = @device_token.plain_token, client: "android/1")
    { "Authorization" => "Bearer #{token}", "X-Emanator-Client" => client, "Accept" => "application/json" }
  end

  def api_get(path, **opts) = get(path, headers: api_headers, **opts)
  def api_post(path, **opts) = post(path, headers: api_headers, as: :json, **opts)
  def api_patch(path, **opts) = patch(path, headers: api_headers, as: :json, **opts)
  def api_delete(path, **opts) = delete(path, headers: api_headers, **opts)

  def json = JSON.parse(response.body)

  # Replaces a singleton method for the duration of the block.
  def override(object, name, value)
    original = object.method(name)
    object.define_singleton_method(name) { |*, **| value }
    yield
  ensure
    object.define_singleton_method(name, original)
  end

  def create_signed_account(user, **attrs)
    user.accounts.create!({
      pubkey_hex: SecureRandom.hex(32), display_name: "Author",
      signer_pubkey: SecureRandom.hex(32), app_privkey: SecureRandom.hex(32), app_pubkey: SecureRandom.hex(32),
      dm_perms_version: Nostr::AuthService::PERMISSIONS_VERSION
    }.merge(attrs))
  end
end
