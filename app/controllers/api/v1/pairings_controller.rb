# frozen_string_literal: true

module Api
  module V1
    # Pairing a signer to a new account, or re-pairing an existing one. Same
    # sessions and the same completion (Accounts::Pairing) as the web pages; the
    # app holds the session id the web keeps in its cookie.
    class PairingsController < BaseController
      # L1: every pairing mints a session and a relay subscription.
      rate_limit to: 10, within: 1.minute, only: :create,
                 by: -> { current_user&.id || request.remote_ip }, with: :rate_limited

      # account_id present = re-pair that account; absent = add a new one.
      def create
        if params[:account_id].blank? && !Billing.can_add_account?(current_user)
          return render_error(I18n.t("billing.account_limit", limit: Billing::FREE_ACCOUNT_LIMIT), status: :payment_required, code: "account_limit")
        end
        current_user.accounts.find(params[:account_id]) if params[:account_id].present?

        data = Accounts::Pairing.start
        render json: {
          session_id: data[:session_id],
          uri: data[:uri],
          relays: data[:relay_urls],
          expires_in: Nostr::AuthService::SESSION_EXPIRY.to_i
        }, status: :created
      end

      # Polled with the session id (the route's :id).
      def show
        pairing = Accounts::Pairing.new(current_user, params[:id])
        result =
          if params[:account_id].present?
            pairing.complete_re_pair(current_user.accounts.find(params[:account_id]))
          else
            pairing.complete_new
          end

        render json: {
          status: result.status.to_s,
          auth_url: result.auth_url,
          error: result.error,
          account: result.account && serializer.account(result.account)
        }
      end

      private

      def rate_limited
        render_error(I18n.t("accounts.pairing_rate_limited"), status: :too_many_requests, code: "rate_limited")
      end
    end
  end
end
