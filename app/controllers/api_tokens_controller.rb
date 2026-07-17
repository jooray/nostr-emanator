# frozen_string_literal: true

class ApiTokensController < ApplicationController
  def create
    name = params[:name].to_s.strip
    if name.blank?
      redirect_to edit_user_path(anchor: "api-tokens"), alert: "Token name required."
      return
    end

    token = ApiToken.generate(current_user, name: name)
    flash[:plain_token] = token.plain_token
    flash[:plain_token_name] = token.name
    redirect_to edit_user_path(anchor: "api-tokens")
  end

  def destroy
    token = current_user.api_tokens.find(params[:id])
    token.destroy
    redirect_to edit_user_path(anchor: "api-tokens"), notice: "Token revoked."
  end
end
