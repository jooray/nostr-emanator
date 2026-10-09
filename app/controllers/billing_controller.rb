# frozen_string_literal: true

# Plans and payment for AI assist on the hosted instance. Answers 404 when
# billing is not configured (self-hosted).
#
# Paying redirects the form post straight to the BTCPay checkout, and BTCPay
# sends the payer back here once the invoice is paid. Billing does not
# authenticate users, so the session remembers which charges it created
# (NostrBilling::ChargeLedger); showing this page checks those, which also
# settles a payment whose webhook has not arrived yet.
class BillingController < ApplicationController
  MIN_SATS = Billing::Checkout::MIN_SATS
  MAX_SATS = Billing::Checkout::MAX_SATS

  before_action :require_billing!

  # The app-wide form-action 'self' would stop the redirect to BTCPay, whose
  # host this app does not know. The forms on this page only post here.
  content_security_policy only: :show do |policy|
    policy.form_action :self, :https
  end

  def show
    settled = Billing.gate.check_charges(current_user.npub, ledger).first
    @snapshot = settled ? settled[:snapshot] : Billing.gate.status(current_user.npub)
    if settled
      flash.now[:notice] = t("billing.charge.settled", date: helpers.billing_date(@snapshot.until_time))
    end
    @plans = Billing.gate.plans&.dig("plans")&.slice(*Billing::PLANS)
  end

  def create_charge
    result = Billing::Checkout.new(current_user, ledger)
                             .create(plan: params[:plan], sats: params[:sats], redirect_url: billing_url)
    return redirect_to(billing_path, alert: result.error) unless result.ok?

    redirect_to result.checkout_url, allow_other_host: true
  end

  private

  def require_billing!
    raise ActionController::RoutingError, "Not Found" unless Billing.enabled?
  end

  def ledger
    @ledger ||= NostrBilling::ChargeLedger.new(session)
  end
end
