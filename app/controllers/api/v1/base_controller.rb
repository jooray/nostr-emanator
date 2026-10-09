# frozen_string_literal: true

module Api
  module V1
    # The native app's API. Same models, services and jobs as the web — these
    # controllers only translate between HTTP+JSON and the operations the web
    # controllers also call, so the two can never disagree about what an action
    # does.
    #
    # Auth is a device token (ApiToken kind "device") in `Authorization: Bearer`.
    # An MCP token is not accepted here: it is handed to AI agents, and this API
    # reaches private messages.
    #
    # Errors are always JSON: { error: "human readable, localized", code: "…" }.
    class BaseController < ActionController::API
      # The shared concerns (AiAssistActions, RequireAiEntitlement) call `t`.
      include AbstractController::Translation


      CLIENT_HEADER = "X-Emanator-Client"

      before_action :require_supported_client!
      before_action :authenticate_device!
      around_action :use_user_time_zone
      around_action :switch_locale
      before_action :trigger_stale_refreshes

      attr_reader :current_user, :current_token

      rescue_from ActiveRecord::RecordNotFound do
        render_error(I18n.t("api.errors.not_found"), status: :not_found, code: "not_found")
      end
      rescue_from ActionController::ParameterMissing do |e|
        render_error(e.message, status: :bad_request, code: "bad_request")
      end
      rescue_from Nostr::EventSignerService::InvalidReferenceError do |e|
        render_error(e.message, status: :unprocessable_entity, code: "invalid_reference")
      end

      private

      def serializer
        @serializer ||= ApiSerializer.new(current_user)
      end

      def render_error(message, status: :unprocessable_entity, code: "invalid", **extra)
        render json: { error: message, code: code, **extra }, status: status
      end

      def authenticate_device!
        @current_token = ApiToken.find_valid(bearer_token, kind: "device")
        @current_user = @current_token&.user
        return if @current_user

        render_error(I18n.t("api.errors.unauthorized"), status: :unauthorized, code: "unauthorized")
      end

      def bearer_token
        header = request.headers["Authorization"].to_s
        header.start_with?("Bearer ") ? header.delete_prefix("Bearer ").strip : nil
      end

      # "android/12" → 12. A client that does not say what it is (curl, a
      # script) is let through: the gate exists to stop *old app builds* from
      # half-working against a newer API, not to fingerprint callers.
      def client_version_code
        request.headers[CLIENT_HEADER].to_s[%r{\Aandroid/(\d+)}, 1]&.to_i
      end

      def require_supported_client!
        version = client_version_code
        return if version.nil? || version >= AndroidApp.min_version_code

        render_error(I18n.t("api.errors.upgrade_required"), status: :upgrade_required, code: "upgrade_required",
                     **AndroidApp.release_info)
      end

      def use_user_time_zone(&block)
        zone = ActiveSupport::TimeZone[current_user&.timezone.to_s]
        zone ? Time.use_zone(zone, &block) : yield
      end

      # The user's own choice (shared with the web), else what the phone asks for.
      def switch_locale(&block)
        available = I18n.available_locales.map(&:to_s)
        requested = request.headers["Accept-Language"].to_s.split(",").map { |p| p.split(";").first.to_s.split("-").first.to_s.downcase }
        locale = ([ current_user&.locale ] + requested).compact.find { |c| available.include?(c) } || I18n.default_locale
        I18n.with_locale(locale, &block)
      end

      def trigger_stale_refreshes
        return unless current_user && request.get?

        CacheRefreshDispatcher.dispatch_if_stale(current_user)
      rescue StandardError => e
        Rails.logger.warn("Stale-refresh dispatch failed: #{e.message}")
      end

      def page_param = [ params[:page].to_i, 1 ].max

      def pagination(scope)
        {
          page: scope.current_page,
          total_pages: scope.total_pages,
          total_count: scope.total_count,
          next_page: scope.next_page
        }
      end
    end
  end
end
