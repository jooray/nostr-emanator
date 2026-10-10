# frozen_string_literal: true

# @mention suggestions for the web composer (mention_controller.js). The app
# asks Api::V1::MentionsController; both run Mentions::Search.
class MentionsController < ApplicationController
  def index
    results = Mentions::Search.call(current_user, params[:q])
    render json: { mentions: results.map { |r| ApiSerializer.new(current_user).mention(r) } }
  end
end
