# frozen_string_literal: true

module Api
  module V1
    # Logging the app in. The shared Android module (nostr-signin, vendored in
    # android/nostr-signin) speaks this contract; Lievik serves the same one.
    #
    # NIP-55 (a signer on the phone, no relays): POST challenge, then token with
    # a NIP-98 proof (kind 27235, u = token_url, method POST, the challenge).
    # The 1.0.x-era kind-22242 proof (challenge + domain, verified like the
    # web's NIP-07 login) is still accepted. The challenge lives in Rails.cache, single-use,
    # CHALLENGE_TTL. The account imported this way has no NIP-46 connection
    # yet, exactly like a NIP-07 web login: it is paired before it can post.
    #
    # NIP-46, through the same sessions as the web login:
    # The app opens the nostrconnect:// URI itself — Amber on the same phone
    # handles it directly, no QR in sight — or shows it as a QR for a signer on
    # another device, or the user pastes a bunker:// link. Then it polls with the
    # session id and the poll_token handed only to the creator (its digest is
    # on the session). Builds before LEGACY_POLL_BELOW sent no poll_token; they
    # are still let through on the session id alone (never part of the URI)
    # until min_version_code passes them.
    #
    # Once the signer answers, the login completes the way the web's does
    # (Sessions::Login) and the app receives a device token.
    class AuthController < BaseController
      CHALLENGE_TTL = 5.minutes
      CHALLENGE_PREFIX = "api-auth-challenge:"
      LEGACY_POLL_BELOW = 2

      skip_before_action :authenticate_device!, except: :destroy

      rate_limit to: 30, within: 1.minute, only: [ :challenge, :token ], name: "api-auth-challenge-ip", with: :rate_limited
      rate_limit to: 5, within: 1.minute, only: :nostrconnect, name: "api-login-ip", with: :rate_limited
      rate_limit to: 60, within: 1.minute, only: :nostrconnect, name: "api-login-global", by: -> { "global" }, with: :rate_limited
      rate_limit to: 10, within: 1.minute, only: :bunker, name: "api-bunker-ip", with: :rate_limited
      rate_limit to: 120, within: 1.minute, only: :poll, name: "api-login-poll-ip", with: :rate_limited

      def challenge
        challenge = SecureRandom.hex(32)
        Rails.cache.write(CHALLENGE_PREFIX + challenge, CHALLENGE_TTL.from_now.to_i, expires_in: CHALLENGE_TTL)
        render json: { challenge: challenge, domain: auth_service.domain, token_url: token_endpoint_url, expires_in: CHALLENGE_TTL.to_i }
      end

      def token
        event = signed_event_param
        challenge = challenge_tag(event)
        return auth_failed unless challenge && consume_challenge(challenge)

        # The app signs a NIP-98 proof (kind 27235) for this endpoint; kind
        # 22242 with a domain tag is still accepted from builds that predate it.
        pubkey_hex = event["pubkey"].to_s
        valid = pubkey_hex.match?(/\A[0-9a-f]{64}\z/) &&
          if event["kind"] == Nostr::AuthService::HTTP_AUTH_KIND
            auth_service.verify_http_auth(event.to_json, challenge, url: token_endpoint_url)
          else
            auth_service.verify_nip07_auth(pubkey_hex, event.to_json, challenge: challenge)
          end
        return auth_failed unless valid

        issue(Sessions::Login.complete!(pubkey_hex))
      end

      def nostrconnect
        data = Sessions::Admission.admit do
          connect = auth_service.generate_connect_uri
          Nip46SupervisorJob.ensure_running
          connect
        end
        return render_error(I18n.t("sessions.errors.capacity_message"), status: :service_unavailable, code: "capacity") unless data

        render json: connect_payload(data).merge(poll_token: issue_poll_token(data[:session_id]))
      end

      def bunker
        result = auth_service.start_bunker_session(params[:bunker_uri])
        return render_error(I18n.t("sessions.bunker.invalid_link"), code: "invalid_link") if result.nil?

        Nip46SupervisorJob.ensure_running
        render json: { session_id: result[:session_id], poll_token: issue_poll_token(result[:session_id]), relays: result[:relay_urls] }
      rescue StandardError => e
        Rails.logger.error("API bunker login failed: #{e.class} - #{e.message}")
        render_error(I18n.t("sessions.bunker.failed"), status: :internal_server_error, code: "failed")
      end

      def poll
        auth_session = NostrAuthSession.active.find_by(session_id: params[:session_id].to_s)
        # Expired, consumed or never existed: say so distinctly, so the app stops
        # polling and offers a fresh start instead of spinning (H9).
        return render json: { status: "expired" } if auth_session.nil?
        return render_error(I18n.t("api.errors.not_found"), status: :not_found, code: "not_found") unless poll_allowed?(auth_session)
        return render json: { status: "pending", auth_url: auth_session.auth_url } unless auth_session.authenticated?

        # Claim the session atomically, so two racing polls never both get a token.
        claimed = NostrAuthSession.active.where(id: auth_session.id).update_all(consumed_at: Time.current) == 1
        return render json: { status: "expired" } unless claimed

        user = Sessions::Login.complete!(auth_session.authenticated_user_pubkey, auth_session: auth_session)
        auth_session.reload.consume!
        issue(user, status: "authenticated")
      end

      # Logs this device out. Only its own token goes — other devices and the
      # web stay signed in.
      def destroy
        current_token.destroy
        head :no_content
      end

      private

      def auth_service = @auth_service ||= Nostr::AuthService.new

      # The URL a NIP-98 proof's `u` tag names.
      def token_endpoint_url = "#{request.base_url}/api/v1/auth/token"

      def issue(user, **extra)
        token = ApiToken.issue_device!(user, name: params[:device_name], client_version: params[:client_version] || client_version_code)
        @current_user = user
        render json: { **extra, token: token.plain_token, token_id: token.id, user: serializer.user(user) }
      end

      def issue_poll_token(session_id)
        plain = SecureRandom.hex(32)
        NostrAuthSession.where(session_id: session_id).update_all(poll_token_digest: ApiToken.digest_for(plain))
        plain
      end

      def poll_allowed?(auth_session)
        digest = auth_session.poll_token_digest
        given = params[:poll_token].to_s
        if given.present?
          digest.present? && ActiveSupport::SecurityUtils.secure_compare(digest, ApiToken.digest_for(given))
        else
          # A build that predates poll tokens (see LEGACY_POLL_BELOW).
          client_version_code.to_i.between?(1, LEGACY_POLL_BELOW - 1)
        end
      end

      def signed_event_param
        raw = params[:signed_event]
        raw = JSON.parse(raw) if raw.is_a?(String)
        raw = raw.to_unsafe_h if raw.respond_to?(:to_unsafe_h)
        raw.is_a?(Hash) ? raw.deep_stringify_keys : nil
      rescue JSON::ParserError
        nil
      end

      def challenge_tag(event)
        return nil unless event && event["tags"].is_a?(Array)

        value = event["tags"].find { |t| t.is_a?(Array) && t.first == "challenge" }&.second
        value.is_a?(String) && value.match?(/\A[0-9a-f]{64}\z/) ? value : nil
      end

      # Single-use: only the request whose delete removed the entry may use it,
      # even if verification then fails. The stored expiry guards against a
      # store that keeps expired rows until they are swept.
      def consume_challenge(challenge)
        key = CHALLENGE_PREFIX + challenge
        expires_at = Rails.cache.read(key)
        return false unless expires_at

        Rails.cache.delete(key) && expires_at.to_i > Time.current.to_i
      end

      def auth_failed
        render_error(I18n.t("sessions.callback.bad_signature"), status: :unauthorized, code: "auth_failed")
      end

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
