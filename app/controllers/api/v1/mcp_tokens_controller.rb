# frozen_string_literal: true

module Api
  module V1
    # MCP tokens for AI agents (Settings → API Tokens on the web). Created here
    # the same way, with the same expiry choices; the plaintext is returned once.
    class McpTokensController < BaseController
      def index
        render json: {
          endpoint: "#{Nostr::AuthService.new.canonical_url}/mcp",
          expiry_options_days: ApiTokensController::EXPIRY_OPTIONS_DAYS,
          tokens: current_user.api_tokens.mcp.order(created_at: :desc).map { |token| token_json(token) }
        }
      end

      def create
        name = params[:name].to_s.strip
        return render_error(I18n.t("api_tokens.create.name_required")) if name.blank?

        days = Integer(params[:expires_in_days].to_s, exception: false)
        days = ApiToken::DEFAULT_EXPIRY.in_days.to_i unless days && ApiTokensController::EXPIRY_OPTIONS_DAYS.include?(days)
        token = ApiToken.generate(current_user, name: name, expires_at: days.zero? ? nil : days.days.from_now)

        render json: token_json(token).merge(token: token.plain_token), status: :created
      end

      def destroy
        current_user.api_tokens.mcp.find(params[:id]).destroy
        head :no_content
      end

      private

      def token_json(token)
        {
          id: token.id,
          name: token.name,
          preview: token.masked_preview,
          created_at: serializer.time(token.created_at),
          expires_at: serializer.time(token.expires_at),
          expired: token.expired?,
          last_used_at: serializer.time(token.last_used_at)
        }
      end
    end
  end
end
