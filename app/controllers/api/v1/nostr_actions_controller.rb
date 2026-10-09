# frozen_string_literal: true

module Api
  module V1
    # Like / follow / mute, signed by the account's signer in the background.
    class NostrActionsController < BaseController
      def create
        account = current_user.accounts.find(params[:account_id])
        action, error = NostrAction.request!(account, action_params)
        return render_error(error) if error

        render json: action_json(action)
      end

      def show
        render json: action_json(find_action)
      end

      def retry
        action = find_action
        return render_error(I18n.t("nostr_actions.not_retryable")) unless action.retryable?

        action.retry!
        render json: action_json(action)
      end

      private

      def action_params
        params.require(:nostr_action).permit(:action_type, :target_event_id, :target_pubkey, :target_event_kind)
      end

      def find_action
        NostrAction.joins(:account).where(accounts: { user_id: current_user.id }).find(params[:id])
      end

      def action_json(action)
        { id: action.id, status: action.status, action_type: action.action_type, error: action.error_message }
      end
    end
  end
end
