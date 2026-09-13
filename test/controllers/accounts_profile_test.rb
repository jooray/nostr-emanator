# frozen_string_literal: true

require_relative "../test_helper"

class AccountsProfileTest < ActionDispatch::IntegrationTest
  include NostrTestHelper
  include SessionHelper

  def setup
    @user = create_signed_in_user
  end

  # The editor reads the live profile from relays so the form starts from what
  # is actually published. Keep the tests off the network.
  # Minitest 6 dropped minitest/mock, and the project has no mocking gem, so
  # swap the constructor by hand and always put it back.
  def without_relay_fetch(event = nil)
    fake = Object.new
    fake.define_singleton_method(:fetch_raw_event) { |_pubkey| event }

    original = Nostr::ProfileFetcher.method(:new)
    Nostr::ProfileFetcher.define_singleton_method(:new) { |*, **| fake }
    yield
  ensure
    Nostr::ProfileFetcher.define_singleton_method(:new, original)
  end

  def paired_account(**attrs)
    @user.accounts.create!({
      pubkey_hex: SecureRandom.hex(32),
      display_name: "Paired",
      signer_pubkey: SecureRandom.hex(32),
      app_privkey: SecureRandom.hex(32),
      app_pubkey: SecureRandom.hex(32),
      dm_perms_version: Nostr::AuthService::PROFILE_PERMISSIONS_VERSION
    }.merge(attrs))
  end

  def test_editor_renders_for_a_capable_account
    account = paired_account

    without_relay_fetch { get profile_account_path(account) }

    assert_response :success
    assert_match(/Nostr profile/, response.body)
    assert_match(/Publish profile/, response.body)
    assert_match(/profile\[display_name\]/, response.body)
    assert_match(/profile\[banner\]/, response.body)
    assert_match(/profile\[lud16\]/, response.body)
  end

  # An account paired before permission version 4 never requested sign_event:0,
  # so it must be told to re-pair rather than shown a button that will fail.
  def test_editor_prompts_a_re_pair_for_an_account_without_profile_permission
    account = paired_account(dm_perms_version: 3)

    without_relay_fetch { get profile_account_path(account) }

    assert_response :success
    assert_match(/Re-pair this account/, response.body)
    assert_match(/disabled/, response.body)
  end

  def test_update_profile_enqueues_a_job_and_returns_a_poll_url
    account = paired_account

    assert_difference "ProfileUpdate.count", 1 do
      post profile_account_path(account), params: { profile: { display_name: "New Name", about: "Hi" } }
    end

    assert_response :success
    body = response.parsed_body
    assert body["ok"]
    assert body["poll_url"].present?

    update = ProfileUpdate.order(:id).last
    assert_equal "New Name", update.edits["display_name"]
    assert_equal @user.id, update.user_id
  end

  def test_update_profile_refuses_an_account_without_profile_permission
    account = paired_account(dm_perms_version: 3)

    assert_no_difference "ProfileUpdate.count" do
      post profile_account_path(account), params: { profile: { display_name: "x" } }
    end

    assert_redirected_to profile_account_path(account)
  end

  # Only the fields the editor offers may be changed; everything else in the
  # published profile is preserved by the merge, not overwritten from here.
  def test_update_profile_ignores_unpermitted_fields
    account = paired_account

    post profile_account_path(account), params: {
      profile: { display_name: "ok", pubkey: "evil", id: "evil" }
    }

    edits = ProfileUpdate.order(:id).last.edits
    assert_equal "ok", edits["display_name"]
    refute edits.key?("pubkey")
    refute edits.key?("id")
  end

  def test_profile_status_reports_progress
    account = paired_account
    update = account.profile_updates.create!(user: @user, status: "running", step: "Approve in your signer…")

    get profile_status_account_path(account, update_id: update.id)

    assert_response :success
    assert_equal "running", response.parsed_body["status"]
    assert_equal "Approve in your signer…", response.parsed_body["step"]
  end

  # A job killed by a deploy leaves the row in `running` forever; the browser
  # must be told it failed rather than polling a spinner indefinitely.
  def test_profile_status_reports_a_stranded_update_as_failed
    account = paired_account
    update = account.profile_updates.create!(user: @user, status: "running")
    update.update_columns(created_at: (ProfileUpdate::STUCK_AFTER + 1.minute).ago)

    get profile_status_account_path(account, update_id: update.id)

    assert_equal "failed", response.parsed_body["status"]
    assert_match(/too long/i, response.parsed_body["error"])
  end

  # Account ids are sequential, so an unscoped lookup is a cross-tenant write.
  def test_another_users_account_is_not_reachable
    other = User.create!(pubkey_hex: SecureRandom.hex(32), npub: "npub1#{SecureRandom.hex(8)}")
    theirs = other.accounts.create!(
      pubkey_hex: SecureRandom.hex(32), signer_pubkey: SecureRandom.hex(32),
      app_privkey: SecureRandom.hex(32), app_pubkey: SecureRandom.hex(32),
      dm_perms_version: Nostr::AuthService::PROFILE_PERMISSIONS_VERSION
    )

    # Rails turns RecordNotFound into a 404 here rather than raising, so assert
    # the outcome: not reachable, and no write happened.
    without_relay_fetch { get profile_account_path(theirs) }
    assert_response :not_found

    assert_no_difference "ProfileUpdate.count" do
      post profile_account_path(theirs), params: { profile: { display_name: "x" } }
    end
    assert_response :not_found
  end

  # Kept deliberately: bumping the permission set for profile editing must not
  # report every already-paired account as incapable of messaging.
  def test_bumping_profile_permissions_does_not_disable_messaging
    account = paired_account(dm_perms_version: Nostr::AuthService::MESSAGING_PERMISSIONS_VERSION)

    assert account.messaging_capable?, "messaging must survive a profile-only permission bump"
    refute account.profile_editing_capable?
  end
end
