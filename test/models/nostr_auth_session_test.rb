# frozen_string_literal: true

require_relative "../test_helper"

class NostrAuthSessionTest < ActiveSupport::TestCase
  def setup
    @auth_session = NostrAuthSession.create!(
      session_id: SecureRandom.uuid,
      temp_pubkey: "1" * 64,
      temp_privkey: "2" * 64,
      secret: "secret",
      relay_url: ["wss://relay.example"].to_json,
      expires_at: 10.minutes.from_now
    )
  end

  def test_listener_lease_blocks_duplicates_and_can_be_recovered
    token = @auth_session.claim_listener!
    assert token
    assert_nil @auth_session.claim_listener!

    @auth_session.update_column(:listener_started_at, NostrAuthSession::LISTENER_LEASE.ago - 1.second)
    replacement = @auth_session.claim_listener!
    assert replacement
    refute_equal token, replacement
    refute @auth_session.renew_listener_lease!(token)
    assert @auth_session.renew_listener_lease!(replacement)
  end

  def test_only_owner_can_release_listener
    token = @auth_session.claim_listener!
    @auth_session.release_listener!("wrong-token")
    assert_equal token, @auth_session.reload.listener_token

    @auth_session.release_listener!(token)
    assert_nil @auth_session.reload.listener_token
  end
end
