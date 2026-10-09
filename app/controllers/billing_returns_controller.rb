# frozen_string_literal: true

# Where BTCPay sends a payer who paid from the Android app. The phone's browser
# has no Emanator session, so this page only hands them back to the app, which
# confirms the charge itself (Api::V1::BillingController#show).
class BillingReturnsController < ApplicationController
  skip_before_action :authenticate_user!

  def show
  end
end
