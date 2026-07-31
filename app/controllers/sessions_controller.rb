# frozen_string_literal: true

class SessionsController < ApplicationController
  # One multiplexed supervisor (Nostr::Nip46Supervisor) serves every pending login
  # at once with O(1) DB/WebSocket connections, so admission is no longer bound to
  # one worker per login. The cap just guards memory / relay subscription fan-out.
  MAX_ACTIVE_AUTH_SESSIONS = ENV.fetch("MAX_ACTIVE_NOSTR_AUTH_SESSIONS", 50).to_i

  skip_before_action :authenticate_user!
  rate_limit to: 5, within: 1.minute, only: :new, name: "nostr-login-ip", with: :rate_limit_exceeded
  rate_limit to: 60, within: 1.minute, only: :new, name: "nostr-login-global", by: -> { "global" }, with: :rate_limit_exceeded

  def new
    consume_pending_sessions!

    # Serialize session creation so a burst can't slip past the capacity check.
    admission_token = SecureRandom.hex(16)
    admitted = Rails.cache.write("nostr-auth-session-admission", admission_token, expires_in: 10.seconds, unless_exist: true)
    unless admitted
      render_capacity_error
      return
    end

    begin
      NostrAuthSession.cleanup_expired!
      if NostrAuthSession.active.where(authenticated_pubkey: nil).count >= MAX_ACTIVE_AUTH_SESSIONS
        render_capacity_error
        return
      end

      session[:nip07_challenge] = SecureRandom.hex(32)
      @connect_data = Nostr::AuthService.new.generate_connect_uri
      session[:nostr_connect_session_id] = @connect_data[:session_id]

      # Ensure the multiplexed listener is running — it will pick up this session
      # from the DB within ~1s. Polls just check the DB for the persisted result.
      Nip46SupervisorJob.ensure_running
    rescue StandardError
      NostrAuthSession.find_by(session_id: @connect_data&.dig(:session_id))&.destroy!
      raise
    ensure
      Rails.cache.delete("nostr-auth-session-admission") if Rails.cache.read("nostr-auth-session-admission") == admission_token
    end

    @qr_code = RQRCode::QRCode.new(@connect_data[:uri])
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

      user = Nostr::AuthService.new.find_or_create_user(auth_session.authenticated_user_pubkey)
      import_primary_account(user, auth_session)
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
      "Refreshing your profile from relays in the background — reload in a few seconds to see changes."
    else
      "Not signed in."
    end

    redirect_back fallback_location: dashboard_path, notice: notice
  end

  def callback
    pubkey_hex = params[:pubkey]

    if pubkey_hex.blank?
      redirect_to nostr_login_path, alert: "Authentication failed: No public key provided"
      return
    end

    unless Nostr::KeyConverter.valid_hex_pubkey?(pubkey_hex)
      redirect_to nostr_login_path, alert: "Authentication failed: Invalid public key format"
      return
    end
    pubkey_hex = pubkey_hex.downcase

    unless Nostr::AuthService.new.verify_nip07_auth(pubkey_hex, params[:signed_event], challenge: session.delete(:nip07_challenge))
      redirect_to nostr_login_path, alert: "Authentication failed: Signature verification failed"
      return
    end

    user = Nostr::AuthService.new.find_or_create_user(pubkey_hex)

    # Auto-import primary account with NIP-46 connection details from login
    import_primary_account(user)
    complete_authentication!(user)

    redirect_to dashboard_path, notice: "Welcome, #{user.display_name_or_npub}!"
  end

  def destroy
    consume_pending_sessions!
    # I2: bump the version so a cookie captured earlier in this session's life
    # stops working the moment the user logs out.
    current_user&.increment!(:session_version)
    reset_session
    redirect_to nostr_login_path, notice: "Logged out successfully"
  end

  private

  def rate_limit_exceeded
    response.set_header("Retry-After", "60")
    render "sessions/rate_limited",
      locals: { title: "Too many attempts", message: "Too many authentication attempts. Please try again shortly." },
      status: :too_many_requests
  end

  def render_capacity_error
    render "sessions/rate_limited",
      locals: { title: "Temporarily at capacity", message: "Authentication is temporarily at capacity. Please try again shortly." },
      status: :service_unavailable
  end

  def import_primary_account(user, auth_session = nil)
    account = user.accounts.find_or_initialize_by(pubkey_hex: user.pubkey_hex)

    if account.new_record?
      account.display_name = user.display_name
      account.username = user.username
      account.about = user.about
      account.picture_url = user.picture_url
    end

    # Store NIP-46 connection details if login was via NIP-46
    account.apply_signer(auth_session) if auth_session&.authenticated_pubkey.present?

    account.save!

    # Fetch write relays in background
    FetchRelayListJob.perform_later(account.id) if account.write_relays.blank?
  rescue ActiveRecord::RecordNotUnique
    # L16: find_or_initialize_by + save! races another request importing the
    # same (user_id, pubkey_hex) account — e.g. an overlapping login poll.
    # Reload the row the other request created instead of 500ing.
    account = user.accounts.find_by!(pubkey_hex: user.pubkey_hex)
    FetchRelayListJob.perform_later(account.id) if account.write_relays.blank?
  end

  def pending_nip46_session
    NostrAuthSession.active.find_by(session_id: session[:nostr_connect_session_id])
  end

  def pending_pairing_session
    NostrAuthSession.active.find_by(session_id: session[:account_pairing_session_id])
  end

  def consume_pending_sessions!
    [pending_nip46_session, pending_pairing_session].compact.uniq.each(&:consume!)
  end

  def complete_authentication!(user)
    consume_pending_sessions!
    reset_session
    session[:user_id] = user.id
    session[:session_version] = user.session_version.to_i
  end
end
