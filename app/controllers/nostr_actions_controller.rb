# frozen_string_literal: true

class NostrActionsController < ApplicationController
  before_action :set_account, only: [:create]
  before_action :set_nostr_action, only: [:show, :retry]

  def create
    action, error = NostrAction.request!(@account, action_params)
    return render json: { success: false, error: error }, status: :unprocessable_entity if error

    render json: { success: true, nostr_action_id: action.id, status: action.status }
  end

  def show
    render json: {
      id: @nostr_action.id,
      status: @nostr_action.status,
      action_type: @nostr_action.action_type,
      error_message: @nostr_action.error_message,
      signed_event_present: @nostr_action.signed_event.present?,
      unsigned_event_present: @nostr_action.unsigned_event.present?
    }
  end

  def retry
    unless @nostr_action.retryable?
      render json: { success: false, error: t("nostr_actions.not_retryable") }, status: :unprocessable_entity
      return
    end

    @nostr_action.retry!
    render json: { success: true, nostr_action_id: @nostr_action.id, status: @nostr_action.status }
  end

  private

  def set_account
    @account = current_user.accounts.find(params[:account_id])
  end

  def action_params
    params.require(:nostr_action).permit(:action_type, :target_event_id, :target_pubkey, :target_event_kind)
  end

  def set_nostr_action
    @nostr_action = NostrAction.joins(:account)
      .where(accounts: { user_id: current_user.id })
      .find(params[:id])
  end
end
