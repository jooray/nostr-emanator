# frozen_string_literal: true

class ApiTokensController < ApplicationController
  # M6: expiry picker options (in days); "0" means no expiry.
  EXPIRY_OPTIONS_DAYS = [ 30, 90, 180, 365, 0 ].freeze

  def create
    name = params[:name].to_s.strip
    if name.blank?
      redirect_to edit_user_path(anchor: "api-tokens"), alert: "Token name required."
      return
    end

    token = ApiToken.generate(current_user, name: name, expires_at: expires_at_from_params)
    flash[:plain_token] = token.plain_token
    flash[:plain_token_name] = token.name
    redirect_to edit_user_path(anchor: "api-tokens")
  end

  def destroy
    token = current_user.api_tokens.find(params[:id])
    token.destroy
    redirect_to edit_user_path(anchor: "api-tokens"), notice: "Token revoked."
  end

  private

  # Resolve the expiry picker value to a Time (or nil for "never"). Falls
  # back to the model default (90 days) for a missing/invalid selection.
  def expires_at_from_params
    raw = params[:expires_in_days].presence
    return ApiToken::DEFAULT_EXPIRY.from_now if raw.nil?

    days = Integer(raw, exception: false)
    return ApiToken::DEFAULT_EXPIRY.from_now if days.nil? || !EXPIRY_OPTIONS_DAYS.include?(days)

    days.zero? ? nil : days.days.from_now
  end
end
