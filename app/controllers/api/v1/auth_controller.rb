# frozen_string_literal: true

module Api
  module V1
    # Logging the app in, through the same NIP-46 sessions as the web login.
    #
    # The app opens the nostrconnect:// URI itself — Amber on the same phone
    # handles it directly, no QR in sight — or shows it as a QR for a signer on
    # another device, or the user pastes a bunker:// link. Then it polls with the
    # session id, which is never part of the URI and so works as the poll's
    # credential, exactly like the web's session cookie does.
    #
    # Once the signer answers, the login completes the way the web's does
    # (Sessions::Login) and the app receives a device token.
    class AuthController < BaseController
      skip_before_action :authenticate_device!, except: :destroy

      rate_limit to: 5, within: 1.minute, only: :nostrconnect, name: "api-login-ip", with: :rate_limited
      rate_limit to: 60, within: 1.minute, only: :nostrconnect, name: "api-login-global", by: -> { "global" }, with: :rate_limited
      rate_limit to: 10, within: 1.minute, only: :bunker, name: "api-bunker-ip", with: :rate_limited
      rate_limit to: 120, within: 1.minute, only: :poll, name: "api-login-poll-ip", with: :rate_limited

      def nostrconnect
        data = Sessions::Admission.admit do
          connect = Nostr::AuthService.new.generate_connect_uri
          Nip46SupervisorJob.ensure_running
          connect
        end
        return render_error(I18n.t("sessions.errors.capacity_message"), status: :service_unavailable, code: "capacity") unless data

        render json: connect_payload(data)
      end

      def bunker
        result = Nostr::AuthService.new.start_bunker_session(params[:bunker_uri])
        return render_error(I18n.t("sessions.bunker.invalid_link"), code: "invalid_link") if result.nil?

        Nip46SupervisorJob.ensure_running
        render json: { session_id: result[:session_id], relays: result[:relay_urls] }
      rescue StandardError => e
        Rails.logger.error("API bunker login failed: #{e.class} - #{e.message}")
        render_error(I18n.t("sessions.bunker.failed"), status: :internal_server_error, code: "failed")
      end

      def poll
        auth_session = NostrAuthSession.active.find_by(session_id: params[:session_id].to_s)
        # Expired, consumed or never existed: say so distinctly, so the app stops
        # polling and offers a fresh start instead of spinning (H9).
        return render json: { status: "expired" } if auth_session.nil?
        return render json: { status: "pending", auth_url: auth_session.auth_url } unless auth_session.authenticated?

        user = Sessions::Login.complete!(auth_session.authenticated_user_pubkey, auth_session: auth_session)
        auth_session.consume!
        token = ApiToken.issue_device!(user, name: params[:device_name], client_version: params[:client_version])

        @current_user = user
        render json: { status: "authenticated", token: token.plain_token, token_id: token.id, user: serializer.user(user) }
      end

      # Logs this device out. Only its own token goes — other devices and the
      # web stay signed in.
      def destroy
        current_token.destroy
        head :no_content
      end

      private

      def connect_payload(data)
        {
          session_id: data[:session_id],
          uri: data[:uri],
          relays: data[:relay_urls],
          expires_in: Nostr::AuthService::SESSION_EXPIRY.to_i
        }
      end

      def rate_limited
        response.set_header("Retry-After", "60")
        render_error(I18n.t("sessions.errors.too_many_message"), status: :too_many_requests, code: "rate_limited")
      end
    end
  end
end
