class ApplicationController < ActionController::Base
  allow_browser versions: :modern

  # Every time this app renders belongs to one person in one place, so render
  # them all in that person's zone rather than the server's.
  #
  # Without this, `l(post.scheduled_at, format: "%H:%M")` formatted in `Time.zone`
  # — which is UTC, since config.time_zone is unset — while `local_time` converted
  # to the browser's zone in JS. The same post therefore read 08:00 on the
  # calendar and 10:00 AM on its own detail page. Setting the zone here fixes the
  # whole class at once: cell times, the forme row's release hour, "Today" and
  # "Tomorrow", and the calendar's day bucketing all come from the same clock,
  # with no flash of a server-rendered UTC value first.
  #
  # Storage is untouched — ActiveRecord persists UTC regardless — and background
  # jobs keep the app default, which is correct: they compare absolute instants.
  around_action :use_user_time_zone

  before_action :authenticate_user!
  before_action :trigger_stale_refreshes

  helper_method :current_user, :user_signed_in?

  # L2: malformed event ids / pubkeys are rejected before signing; surface that
  # as a 422 instead of a 500.
  rescue_from Nostr::EventSignerService::InvalidReferenceError do |error|
    respond_to do |format|
      format.json { render json: { success: false, error: error.message }, status: :unprocessable_entity }
      format.html { redirect_back fallback_location: root_path, alert: error.message }
    end
  end

  private

  def use_user_time_zone(&block)
    zone = ActiveSupport::TimeZone[current_user&.timezone.to_s]
    return yield unless zone

    Time.use_zone(zone, &block)
  end

  def current_user
    return @current_user if defined?(@current_user) && @current_user
    return nil if session[:user_id].blank?

    user = User.find_by(id: session[:user_id])
    # I2: a cookie minted before the user last logged out (or before an explicit
    # "sign out everywhere") carries a stale version and is no longer accepted.
    # Sessions created before this column existed have no stamp; those are only
    # honoured while the user has never bumped their version.
    stamped = session[:session_version] || 0
    return nil if user && stamped != user.session_version.to_i

    @current_user = user
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
