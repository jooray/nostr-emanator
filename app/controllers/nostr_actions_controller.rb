# frozen_string_literal: true

class NostrActionsController < ApplicationController
  before_action :set_account, only: [:create]
  before_action :set_nostr_action, only: [:show, :retry]

  def create
    # Check for duplicate — return existing if found
    existing = find_existing_action
    if existing
      render json: { success: true, nostr_action_id: existing.id, status: existing.status }
      return
    end

    nostr_action = @account.nostr_actions.build(action_params)

    if nostr_action.save
      ProcessNostrActionJob.perform_later(nostr_action.id)
      render json: { success: true, nostr_action_id: nostr_action.id, status: nostr_action.status }
    else
      render json: { success: false, error: nostr_action.errors.full_messages.join(", ") }, status: :unprocessable_entity
    end
  rescue ActiveRecord::RecordNotUnique
    # M13: lost a race against a concurrent create for the same natural key
    # (account_id, action_type, target_event_id, target_pubkey) — reload the
    # row that won instead of 500ing. If it had permanently failed, resurrect
    # it for a retry rather than leaving the user stuck with no way to redo
    # the action from the UI they just used.
    existing = @account.nostr_actions.find_by(
      action_type: action_params[:action_type],
      target_event_id: action_params[:target_event_id],
      target_pubkey: action_params[:target_pubkey]
    )
    return render json: { success: false, error: "Duplicate action" }, status: :unprocessable_entity unless existing

    if existing.failed?
      existing.update!(status: :pending, error_message: nil, publish_results: nil)
      ProcessNostrActionJob.perform_later(existing.id)
    end
    render json: { success: true, nostr_action_id: existing.id, status: existing.status }
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
    can_retry = @nostr_action.awaiting_signature? || (@nostr_action.failed? && @nostr_action.unsigned_event.present? && @nostr_action.signed_event.blank?)

    unless can_retry
      render json: { success: false, error: "Action is not waiting for a retry." }, status: :unprocessable_entity
      return
    end

    @nostr_action.update!(status: :pending, error_message: nil, publish_results: nil)
    ProcessNostrActionJob.perform_later(@nostr_action.id)

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

  def find_existing_action
    scope = @account.nostr_actions.where.not(status: :failed)

    case params.dig(:nostr_action, :action_type)
    when "reaction"
      scope.reactions_for_event(@account.id, params.dig(:nostr_action, :target_event_id)).first
    when "follow"
      scope.follows_for_pubkey(@account.id, params.dig(:nostr_action, :target_pubkey)).first
    when "mute"
      scope.mutes_for_pubkey(@account.id, params.dig(:nostr_action, :target_pubkey)).first
    end
  end
end
