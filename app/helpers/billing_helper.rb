# frozen_string_literal: true

module BillingHelper
  # The current user's AI entitlement, once per request. nil when billing is
  # disabled, so callers can skip all billing UI with one check.
  def ai_billing_snapshot
    return nil unless Billing.enabled? && current_user

    @ai_billing_snapshot ||= Billing.gate.status(current_user.npub)
  end

  # The dates follow "until" / "do" / "hasta el", so the stock :long formats do
  # not fit: English pads the day ("October 05"), and rails-i18n's sk and cs use
  # the nominative month ("07. Marec"), where Slovak and Czech need the
  # genitive. Those two get the numeric form people write anyway.
  def billing_date(time)
    return "" unless time

    date = time.to_date
    case I18n.locale
    when :en then date.strftime("%B %-d, %Y")
    when :sk, :cs then date.strftime("%-d. %-m. %Y")
    else l(date, format: :long)
    end
  end

  def billing_sats(amount)
    number_with_delimiter(amount.to_i, delimiter: I18n.locale == :en ? "," : " ")
  end
end
