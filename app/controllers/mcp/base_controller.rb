# frozen_string_literal: true

module Mcp
  # Base for MCP endpoints. Authenticates via `Authorization: Bearer <api token>`
  # and exposes the owning user as current_user.
  class BaseController < ActionController::API
    before_action :authenticate_api_token!

    attr_reader :current_user

    private

    def authenticate_api_token!
      token = bearer_token
      @current_user = ApiToken.authenticate(token) if token.present?

      return if @current_user

      render json: { error: "unauthorized" }, status: :unauthorized
    end

    def bearer_token
      header = request.headers["Authorization"].to_s
      return nil unless header.start_with?("Bearer ")

      header.sub(/\ABearer\s+/, "").strip
    end
  end
end
