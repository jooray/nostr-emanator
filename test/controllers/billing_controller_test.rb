# frozen_string_literal: true

require_relative "../test_helper"

class BillingControllerTest < ActionDispatch::IntegrationTest
  include NostrTestHelper
  include SessionHelper
  include BillingTestHelper

  def setup
    @user = create_signed_in_user
  end

  def test_show_lists_both_plans_and_the_state
    get billing_path

    assert_response :success
    assert_select "[data-billing-state=none]"
    assert_select "[data-plan=emanator-ai]"
    assert_select "[data-plan=all-access]"
    assert_select "[data-plan=nalgorithm]", count: 0
  end

  def test_show_mentions_other_products_from_all_access
    @billing.grant(@user.npub, "all-access", 20.days.from_now)
    get billing_path

    assert_select "[data-billing-state=active]"
    assert_match "nalgorithm", response.body
  end

  def test_show_survives_billing_down
    @billing.failure = NostrBilling::Unavailable.new("down")
    get billing_path

    assert_response :success
    assert_select "[data-billing-state=unknown]"
    assert_select ".alarm"
  end

  def test_paying_goes_straight_to_btcpay
    post billing_charges_path, params: { plan: "all-access" }

    charge = billing_calls(:create_charge).last
    assert_equal [ @user.npub, "all-access", nil, billing_url ], charge[1..]
    assert_redirected_to "https://pay.example.test/i/inv_1"
  end

  def test_the_page_btcpay_returns_to_reports_the_payment_once
    post billing_charges_path, params: { plan: "all-access" }
    @billing.settle!("inv_1")

    get billing_path
    assert_select "[data-billing-state=active]"
    assert_match "Paid. AI writing is active until", flash[:notice]
    assert_equal "active", Billing.gate.status(@user.npub).state

    get billing_path
    assert_nil flash[:notice]
  end

  def test_an_unpaid_charge_changes_nothing
    post billing_charges_path, params: { plan: "emanator-ai" }
    get billing_path

    assert_select "[data-billing-state=none]"
    assert_nil flash[:notice]
  end

  def test_the_billing_page_lets_its_forms_redirect_to_btcpay
    get billing_path
    assert_match "form-action 'self' https:", response.headers["Content-Security-Policy"]

    get edit_user_path
    assert_no_match "form-action 'self' https:", response.headers["Content-Security-Policy"]
  end

  def test_settings_links_to_billing
    @billing.grant(@user.npub, "emanator-ai", Time.utc(2030, 3, 7))
    get edit_user_path
    assert_select "#ai-writing a[href=?]", billing_path
    assert_match "Paid until March 7, 2030.", response.body
  end

  def test_custom_amount
    post billing_charges_path, params: { plan: "emanator-ai", sats: "2500" }
    assert_equal 2500, billing_calls(:create_charge).last[3]
  end

  def test_rejects_bad_input_without_calling_billing
    post billing_charges_path, params: { plan: "lievik" }
    assert_redirected_to billing_path
    post billing_charges_path, params: { plan: "emanator-ai", sats: "10" }
    assert_redirected_to billing_path
    assert_empty billing_calls(:create_charge)
  end

  def test_charges_of_another_session_are_not_checked
    @billing.create_charge("npub1someoneelse", plan: "emanator-ai")
    @billing.settle!("inv_1")
    get billing_path

    assert_nil flash[:notice]
    assert_empty billing_calls(:charge)
  end

  def test_billing_down_when_paying
    @billing.failure = NostrBilling::Unavailable.new("down")
    post billing_charges_path, params: { plan: "emanator-ai" }
    assert_redirected_to billing_path
    assert flash[:alert].present?
  end

  def test_pages_render_in_every_language
    %w[sk cs es].each do |locale|
      patch user_path, params: { locale: locale }
      get billing_path
      assert_response :success
      post billing_charges_path, params: { plan: "emanator-ai" }
      assert_response :redirect
    end
  end
end
