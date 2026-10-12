# frozen_string_literal: true

class SessionsController < ApplicationController
  skip_before_action :authenticate_user!
  rate_limit to: 5, within: 1.minute, only: :new, name: "nostr-login-ip", with: :rate_limit_exceeded
  rate_limit to: 60, within: 1.minute, only: :new, name: "nostr-login-global", by: -> { "global" }, with: :rate_limit_exceeded
  # Pasting a bunker URI creates a session and makes us publish to relays, so it
  # needs its own ceiling; a few fat-fingered pastes are normal, a flood is not.
  rate_limit to: 10, within: 1.minute, only: :bunker, name: "nostr-bunker-ip", with: :rate_limit_exceeded

  def new
    consume_pending_sessions!

    @connect_data = Sessions::Admission.admit do
      session[:nip07_challenge] = SecureRandom.hex(32)
      data = Nostr::AuthService.new.generate_connect_uri
      session[:nostr_connect_session_id] = data[:session_id]
      # Ensure the multiplexed listener is running — it will pick up this
      # session from the DB within ~1s. Polls just check the DB for the result.
      Nip46SupervisorJob.ensure_running
      data
    end
    return render_capacity_error unless @connect_data

    @qr_code = RQRCode::QRCode.new(@connect_data[:uri])
  end

  # bunker:// login. The user pastes a URI naming their signer, so we replace
  # whatever nostrconnect session this page started with and speak first.
  # Responds JSON; the page then polls the same endpoint as the QR flow.
  def bunker
    consume_pending_sessions!

    result = Nostr::AuthService.new.start_bunker_session(params[:bunker_uri])

    if result.nil?
      render json: {
        ok: false,
        error: t(".invalid_link")
      }, status: :unprocessable_content
      return
    end

    session[:nostr_connect_session_id] = result[:session_id]
    Nip46SupervisorJob.ensure_running

    render json: { ok: true, relays: result[:relay_urls] }
  rescue StandardError => e
    Rails.logger.error("Bunker login failed: #{e.class} - #{e.message}")
    render json: { ok: false, error: t(".failed") },
           status: :internal_server_error
  end

  def poll
    session_id = session[:nostr_connect_session_id]

    if session_id.blank?
      render json: { authenticated: false, error: "No pending session" }
      return
    end

    # DB-only check — background job handles the relay subscription
    result = Nostr::AuthService.new.check_session(session_id)

    # check_session returns nil once the session is expired, consumed, or gone
    # — surface that distinctly so the poller can stop and prompt for a fresh QR
    # instead of polling "authenticated: false" forever (H9).
    if result.nil?
      render json: { authenticated: false, expired: true }
      return
    end

    if result[:authenticated]
      auth_session = pending_nip46_session
      unless auth_session&.authenticated_user_pubkey == result[:pubkey]
        return render json: { authenticated: false, error: "Authentication session mismatch" }
      end

      user = Sessions::Login.complete!(auth_session.authenticated_user_pubkey, auth_session: auth_session)
      complete_authentication!(user)
      render json: { authenticated: true, redirect_url: dashboard_path }
      return
    end

    render json: { authenticated: false, auth_url: pending_nip46_session&.auth_url }
  end

  def refresh_profile
    # H11: fetching a kind-0 from relays blocks for seconds; do it in a job and
    # say only what is actually true at this point.
    notice = if current_user
      FetchUserProfileJob.perform_later(current_user.id)
      t(".refreshing")
    else
      t(".not_signed_in")
    end

    redirect_back fallback_location: dashboard_path, notice: notice
  end

  def callback
    pubkey_hex = params[:pubkey]

    if pubkey_hex.blank?
      redirect_to nostr_login_path, alert: t(".no_pubkey")
      return
    end

    unless Nostr::KeyConverter.valid_hex_pubkey?(pubkey_hex)
      redirect_to nostr_login_path, alert: t(".invalid_pubkey")
      return
    end
    pubkey_hex = pubkey_hex.downcase

    unless Nostr::AuthService.new.verify_nip07_auth(pubkey_hex, params[:signed_event], challenge: session.delete(:nip07_challenge))
      redirect_to nostr_login_path, alert: t(".bad_signature")
      return
    end

    user = Sessions::Login.complete!(pubkey_hex)
    complete_authentication!(user)

    redirect_to dashboard_path, notice: t(".welcome", name: user.display_name_or_npub)
  end

  def destroy
    consume_pending_sessions!
    # I2: bump the version so a cookie captured earlier in this session's life
    # stops working the moment the user logs out.
    current_user&.increment!(:session_version)
    reset_session
    redirect_to nostr_login_path, notice: t(".logged_out")
  end

  private

  def rate_limit_exceeded
    response.set_header("Retry-After", "60")
    render "sessions/rate_limited",
      locals: { title: I18n.t("sessions.errors.too_many_title"), message: I18n.t("sessions.errors.too_many_message") },
      status: :too_many_requests
  end

  def render_capacity_error
    render "sessions/rate_limited",
      locals: { title: I18n.t("sessions.errors.capacity_title"), message: I18n.t("sessions.errors.capacity_message") },
      status: :service_unavailable
  end

  def pending_nip46_session
    NostrAuthSession.active.find_by(session_id: session[:nostr_connect_session_id])
  end

  def pending_pairing_session
    NostrAuthSession.active.find_by(session_id: session[:account_pairing_session_id])
  end

  def consume_pending_sessions!
    [ pending_nip46_session, pending_pairing_session ].compact.uniq.each(&:consume!)
  end

  def complete_authentication!(user)
    consume_pending_sessions!
    reset_session
    session[:user_id] = user.id
    session[:session_version] = user.session_version.to_i
  end
end
