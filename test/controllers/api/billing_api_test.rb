# frozen_string_literal: true

require_relative "../../test_helper"

class BillingApiTest < ActionDispatch::IntegrationTest
  include ApiTestHelper
  include BillingTestHelper

  def setup
    @user = create_api_user
    @account = create_signed_account(@user)
  end

  def test_status_and_plans
    api_get "/api/v1/billing"

    assert_response :success
    assert_equal "none", json["state"]
    assert_equal %w[emanator-ai all-access], json["plans"].map { |p| p["id"] }
  end

  def test_paying_returns_a_checkout_link_and_reports_settlement_once
    api_post "/api/v1/billing/charges", params: { plan: "emanator-ai" }
    assert_response :created
    assert_equal "https://pay.example.test/i/inv_1", json["checkout_url"]
    assert_equal "http://www.example.com/billing/return", billing_calls(:create_charge).last.last

    @billing.settle!("inv_1")
    api_get "/api/v1/billing"
    assert_equal "active", json["state"]
    assert_equal "emanator-ai", json.dig("settled", "plan")

    api_get "/api/v1/billing"
    assert_nil json["settled"]
  end

  def test_bad_amount_is_refused
    api_post "/api/v1/billing/charges", params: { plan: "emanator-ai", sats: 5 }
    assert_response :unprocessable_entity
  end

  def test_ai_paywall_is_json_before_any_stream
    @billing.grant(@user.npub, "emanator-ai", 1.day.ago)
    api_post "/api/v1/ai/generate_stream", params: { account_id: @account.id, prompt: "hi" }

    assert_response :payment_required
    assert_equal "application/json", response.media_type
    assert_equal "paywall", json["code"]
  end

  def test_billing_404_when_disabled
    Billing.gate = NostrBilling::Gate.new(product: Billing::PRODUCT, client: nil, cache: Billing::Cache)
    api_get "/api/v1/billing"
    assert_response :not_found
  end
end
