# frozen_string_literal: true

# Gates AiAssistController on the hosted instance. With billing disabled both
# callbacks return at once.
#
# Order matters and is set in the controller: entitlement first, then the
# hourly rate limits, then the daily units. An unpaid user never touches the
# hourly bucket, and a rate-limited request never spends units.
#
# Denials are real HTTP statuses with a JSON body, sent before any SSE header,
# so content_builder_controller.js can tell a paywall from a dropped stream:
#   402 paywall              no trial and no paid time
#   429 daily_cap            the daily safety cap (not the hourly rate limit)
#   503 billing_unavailable  billing is down and nothing cached says the user paid
module RequireAiEntitlement
  extend ActiveSupport::Concern

  private

  # The first real AI request starts the 3-day trial. "Real" means the account
  # is the user's and there is a prompt, so a forged or empty request cannot
  # burn the one-time trial.
  def require_ai_entitlement!
    return unless Billing.enabled?

    current_user.accounts.find(params[:account_id])
    snapshot = ai_prompt.present? ? Billing.gate.activate(current_user.npub) : Billing.gate.status(current_user.npub)
    return if snapshot.allows?

    snapshot.unknown? ? deny_billing_unavailable : deny_paywall
  end

  def consume_ai_units!
    return unless Billing.enabled?

    kind = action_name.start_with?("refine") ? "refine" : "generate"
    # A stream makes two model calls (draft, then humanize).
    units = action_name.end_with?("_stream") ? 2 : 1
    case Billing.gate.consume(current_user.npub, kind: kind, units: units, key: request.request_id)
    when :allowed then nil
    when :capped then render_ai_denial(:too_many_requests, "daily_cap", t("ai_assist.daily_cap"))
    when :not_entitled then deny_paywall
    else deny_billing_unavailable
    end
  end

  def ai_prompt
    action_name.start_with?("refine") ? params[:user_prompt].presence || params[:prompt] : params[:prompt]
  end

  def deny_paywall
    render_ai_denial(:payment_required, "paywall", t("ai_assist.paywall"), billing_url: billing_path)
  end

  def deny_billing_unavailable
    render_ai_denial(:service_unavailable, "billing_unavailable", t("ai_assist.billing_unavailable"))
  end

  # The 402 carries the billing page, not a checkout link, so blocked clicks do
  # not create BTCPay invoices.
  def render_ai_denial(status, code, message, **extra)
    render json: { error: message, code: code, **extra }, status: status
  end
end
