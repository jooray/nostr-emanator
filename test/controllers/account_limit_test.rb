# frozen_string_literal: true

require_relative "../test_helper"

# On the hosted instance a user without a trial or paid time may pair up to
# Billing::FREE_ACCOUNT_LIMIT accounts. Self-hosted (billing off) has no limit.
class AccountLimitTest < ActionDispatch::IntegrationTest
  include NostrTestHelper
  include SessionHelper
  include BillingTestHelper

  def setup
    @user = create_signed_in_user
  end

  def add_accounts(count)
    count.times { |i| @user.accounts.create!(pubkey_hex: SecureRandom.hex(32), display_name: "A#{i}") }
  end

  def test_free_user_below_the_limit_can_pair
    add_accounts(Billing::FREE_ACCOUNT_LIMIT - 1 - @user.accounts.count)
    get new_account_path
    assert_response :success
  end

  def test_free_user_at_the_limit_is_stopped_before_the_qr
    add_accounts(Billing::FREE_ACCOUNT_LIMIT - @user.accounts.count)
    get new_account_path

    assert_redirected_to accounts_path
    assert_match "10", flash[:alert]
  end

  def test_trial_or_paid_lifts_the_limit
    add_accounts(Billing::FREE_ACCOUNT_LIMIT - @user.accounts.count)
    @billing.grant(@user.npub, "emanator-ai", 20.days.from_now)

    get new_account_path
    assert_response :success
  end

  def test_expired_user_over_the_limit_keeps_accounts_but_cannot_add
    add_accounts(Billing::FREE_ACCOUNT_LIMIT + 2 - @user.accounts.count)
    @billing.grant(@user.npub, "emanator-ai", 1.day.ago)

    get new_account_path
    assert_redirected_to accounts_path
    assert_equal Billing::FREE_ACCOUNT_LIMIT + 2, @user.accounts.count
  end

  # `new` is what puts the pairing session in the cookie, so the user starts
  # pairing on a trial and the trial ends before the signer answers.
  def test_create_refuses_a_new_account_at_the_limit_but_allows_re_pairing
    add_accounts(Billing::FREE_ACCOUNT_LIMIT - @user.accounts.count)
    @billing.grant(@user.npub, "emanator-ai", 1.minute.from_now)
    get new_account_path
    assert_response :success
    @billing.grant(@user.npub, "emanator-ai", 1.day.ago)
    Billing.gate.invalidate(@user.npub)
    pairing = NostrAuthSession.order(:id).last

    pairing.update!(authenticated_pubkey: SecureRandom.hex(32), authenticated_user_pubkey: SecureRandom.hex(32))
    assert_no_difference -> { @user.accounts.count } do
      post accounts_path
    end
    assert_redirected_to accounts_path
    assert_match "10", flash[:alert]
    follow_redirect!

    pairing.update!(authenticated_user_pubkey: @user.accounts.first.pubkey_hex)
    post accounts_path
    assert_nil flash[:alert]
  end
end

class AccountLimitWithoutBillingTest < ActionDispatch::IntegrationTest
  include NostrTestHelper
  include SessionHelper

  def test_no_limit_when_billing_is_off
    user = create_signed_in_user
    12.times { |i| user.accounts.create!(pubkey_hex: SecureRandom.hex(32), display_name: "A#{i}") }
    get new_account_path
    assert_response :success
  end
end
