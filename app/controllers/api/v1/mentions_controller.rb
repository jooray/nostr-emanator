# frozen_string_literal: true

module Api
  module V1
    # @mention suggestions for the composer, the same lookup as the web's
    # MentionsController (Mentions::Search).
    class MentionsController < BaseController
      def index
        results = Mentions::Search.call(current_user, params[:q])
        render json: { mentions: results.map { |r| serializer.mention(r) } }
      end
    end
  end
end
