class ApplicationController < ActionController::Base
  allow_browser versions: :modern

  before_action :authenticate_user!
  before_action :trigger_stale_refreshes

  helper_method :current_user, :user_signed_in?

  private

  def current_user
    @current_user ||= User.find_by(id: session[:user_id]) if session[:user_id]
  end

  def user_signed_in?
    current_user.present?
  end

  def authenticate_user!
    unless user_signed_in?
      redirect_to nostr_login_path, alert: "Please sign in to continue"
    end
  end

  # Non-blocking: checks each domain cache's freshness and fires refresh
  # jobs via CacheRefreshDispatcher (which enforces a 30 s in-flight guard
  # so rapid page navigation doesn't stack duplicate jobs).
  def trigger_stale_refreshes
    return unless user_signed_in? && request.get?
    CacheRefreshDispatcher.dispatch_if_stale(current_user)
  rescue StandardError => e
    Rails.logger.warn("Stale-refresh dispatch failed: #{e.message}")
  end
end
