# frozen_string_literal: true

module Api
  module V1
    # Signed-in phones (device tokens) — the same list the web Settings page
    # shows, so a lost phone can be signed out from either side.
    class DevicesController < BaseController
      def index
        render json: {
          devices: current_user.api_tokens.device.order(last_used_at: :desc, created_at: :desc).map do |token|
            {
              id: token.id,
              name: token.name,
              client_version: token.client_version,
              created_at: serializer.time(token.created_at),
              last_used_at: serializer.time(token.last_used_at),
              current: token.id == current_token.id
            }
          end
        }
      end

      def destroy
        current_user.api_tokens.device.find(params[:id]).destroy
        head :no_content
      end
    end
  end
end
