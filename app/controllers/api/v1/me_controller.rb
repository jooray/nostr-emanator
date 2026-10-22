# frozen_string_literal: true

module Api
  module V1
    # The signed-in user, their settings (shared with the web) and the status
    # counts that drive the app's badges.
    class MeController < BaseController
      THEMES = %w[system light dark].freeze
      VIEWERS = %w[njump yakihonne].freeze

      def show
        render json: me_payload
      end

      # Everything the web Settings page can change, in one PATCH. Only the keys
      # present are touched.
      def update
        user = current_user
        user.locale = params[:locale] if params.key?(:locale)
        user.timezone = params[:timezone] if params[:timezone].present? && ActiveSupport::TimeZone[params[:timezone].to_s]
        user.theme = params[:theme] if THEMES.include?(params[:theme])
        user.event_viewer = params[:event_viewer] if VIEWERS.include?(params[:event_viewer])
        User::SHARE_NETWORKS.each { |network| user.public_send("#{network}_share=", params["#{network}_share"]) if params.key?("#{network}_share") }
        user.custom_relays = params[:custom_relays] if params.key?(:custom_relays)
        %i[display_name username about].each { |field| user.public_send("#{field}=", params[field]) if params.key?(field) }

        return render_error(user.errors.full_messages.join(" ")) unless user.save

        MediaPreferences.update!(user, params[:media].permit(*MediaPreferences::DEFAULTS.keys).to_h) if params[:media].respond_to?(:permit)
        I18n.locale = user.locale || I18n.locale
        render json: me_payload
      end

      # Cheap enough to poll: the badge numbers and nothing else.
      def summary
        render json: summary_payload
      end

      def refresh_profile
        FetchUserProfileJob.perform_later(current_user.id)
        render json: { ok: true, message: I18n.t("sessions.refresh_profile.refreshing") }
      end

      private

      def me_payload
        {
          user: serializer.user(current_user),
          summary: summary_payload,
          billing_enabled: Billing.enabled?,
          device: { id: current_token.id, name: current_token.name }
        }
      end

      def summary_payload
        Dashboard::StationStatus.for(current_user).merge(
          unread_messages: current_user.conversations.active.known.sum(:unread_count),
          has_requests: current_user.conversations.active.request.with_unread.exists?
        )
      end
    end
  end
end
