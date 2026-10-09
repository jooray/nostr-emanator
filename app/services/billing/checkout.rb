# frozen_string_literal: true

module Billing
  # Turns "pay for this plan" into a BTCPay checkout link, for the web billing
  # page and the native app alike. Billing does not authenticate users, so the
  # charges a payer creates are remembered in a ledger (NostrBilling::
  # ChargeLedger) — the Rails session on the web, the user row for the app.
  class Checkout
    MIN_SATS = 1_000
    MAX_SATS = 1_000_000

    Result = Struct.new(:checkout_url, :invoice_id, :error, keyword_init: true) do
      def ok? = checkout_url.present?
    end

    def initialize(user, ledger)
      @user = user
      @ledger = ledger
    end

    # sats is optional (nil = the plan's own price, otherwise a pro-rata amount).
    def create(plan:, sats:, redirect_url:)
      plan = plan.to_s
      return failure(I18n.t("billing.errors.unknown_plan")) unless PLANS.include?(plan)

      sats = sats.presence&.to_i
      if sats && !(MIN_SATS..MAX_SATS).cover?(sats)
        return failure(I18n.t("billing.errors.sats_range", min: MIN_SATS, max: MAX_SATS))
      end

      charge = Billing.gate.create_charge(@user.npub, plan: plan, sats: sats, redirect_url: redirect_url)
      checkout_url = self.class.safe_checkout_url(charge["checkout_url"])
      return failure(I18n.t("billing.errors.unavailable")) unless checkout_url

      @ledger.remember(charge["invoice_id"], checkout_url: checkout_url, plan: plan)
      Result.new(checkout_url: checkout_url, invoice_id: charge["invoice_id"])
    rescue NostrBilling::Error => e
      Rails.logger.warn("[billing] charge for #{@user.npub} failed: #{e.message}")
      failure(I18n.t("billing.errors.unavailable"))
    end

    # Only an https checkout URL is followed.
    def self.safe_checkout_url(value)
      uri = URI.parse(value.to_s)
      uri.is_a?(URI::HTTPS) && uri.host.present? ? uri.to_s : nil
    rescue URI::InvalidURIError
      nil
    end

    private

    def failure(message) = Result.new(error: message)
  end

  # A ChargeLedger store kept on the user row, for clients without a browser
  # session. Hash-like, which is all ChargeLedger asks of a store.
  class UserLedgerStore
    SETTING = "billing_charges"

    def initialize(user)
      @user = user
    end

    def [](key)
      key.to_s == NostrBilling::ChargeLedger::SESSION_KEY ? @user.settings&.dig(SETTING) : nil
    end

    def []=(key, value)
      return unless key.to_s == NostrBilling::ChargeLedger::SESSION_KEY

      @user.update_column(:settings, (@user.settings || {}).merge(SETTING => value))
    end
  end
end
