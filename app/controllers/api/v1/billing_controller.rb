# frozen_string_literal: true

module Api
  module V1
    # Paid AI assist: status, plans, and paying. Billing does not authenticate
    # payers, so the charges this user created are remembered on the user row
    # (Billing::UserLedgerStore) — the app's equivalent of the web session.
    #
    # Paying opens the BTCPay checkout in the phone's browser. BTCPay sends the
    # payer back to /billing/return, a public page that hands them back to the
    # app; the app then asks here, and the settled charge is reported once.
    class BillingController < BaseController
      before_action :require_billing!

      def show
        settled = Billing.gate.check_charges(current_user.npub, ledger).first
        snapshot = settled ? settled[:snapshot] : Billing.gate.status(current_user.npub)
        render json: serializer.billing(snapshot, plans: Billing.gate.plans&.dig("plans"),
                                                  settled: settled && { plan: settled[:plan], invoice_id: settled[:id] })
      end

      def create_charge
        result = Billing::Checkout.new(current_user, ledger)
                                  .create(plan: params[:plan], sats: params[:sats], redirect_url: billing_return_url)
        return render_error(result.error, code: "charge_failed") unless result.ok?

        render json: { checkout_url: result.checkout_url, invoice_id: result.invoice_id }, status: :created
      end

      private

      def require_billing!
        render_error(I18n.t("api.errors.not_found"), status: :not_found, code: "billing_disabled") unless Billing.enabled?
      end

      def ledger
        @ledger ||= NostrBilling::ChargeLedger.new(Billing::UserLedgerStore.new(current_user))
      end
    end
  end
end
