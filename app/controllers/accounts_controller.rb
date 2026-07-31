# frozen_string_literal: true

class AccountsController < ApplicationController
  before_action :set_account, only: [:show, :edit, :update, :destroy, :refresh_profile, :refresh_relays, :re_pair, :re_pair_poll, :settings, :recent_events, :recent_interactions]

  # L1: generate_connect_uri creates a NostrAuthSession and a subscription on
  # the supervisor's shared relay sockets; cap how often a user can mint new
  # pairing sessions (self-heals after the 5-min TTL either way, but no
  # reason to allow unbounded churn from a stuck client or a script).
  rate_limit to: 10, within: 1.minute, only: [ :new, :re_pair ],
             by: -> { current_user&.id || request.remote_ip }, with: :pairing_rate_limited

  def index
    @accounts = current_user.accounts.order(:created_at)
    # M16: avoid an `account.posts.count` query per card in the view.
    @post_counts = Post.where(account_id: @accounts.map(&:id)).group(:account_id).count
  end

  def show
    # Page renders instantly; events and interactions load via Turbo Frames
    @scheduled_posts = @account.posts.upcoming.includes(:reposts)
  end

  def settings
  end

  def recent_events
    @recent_events = fetch_recent_events
    render layout: false
  end

  def recent_interactions
    @interactions = fetch_recent_interactions
    render layout: false
  end

  def new
    @account = current_user.accounts.build

    # Reuse an in-progress pairing session (e.g. a second tab, or a reload of
    # this same tab) instead of consuming it — killing an active session out
    # from under a QR the user already scanned in another tab strands that
    # tab's poller forever (L28).
    existing_session = pending_pairing_session
    if existing_session
      @connect_data = connect_data_from_session(existing_session)
    else
      @connect_data = Nostr::AuthService.new.generate_connect_uri
      session[:account_pairing_session_id] = @connect_data[:session_id]
    end

    Nip46SupervisorJob.ensure_running
    @qr_code = RQRCode::QRCode.new(@connect_data[:uri])
  end

  def create
    auth_session = NostrAuthSession.active.find_by(session_id: session[:account_pairing_session_id])

    unless auth_session&.authenticated?
      redirect_to new_account_path, alert: "Pairing session expired or not yet authenticated"
      return
    end

    user_pubkey = auth_session.authenticated_user_pubkey
    @account = current_user.accounts.find_or_initialize_by(pubkey_hex: user_pubkey)
    @account.assign_attributes(npub: Nostr::KeyConverter.hex_to_npub(user_pubkey))
    @account.apply_signer(auth_session)

    if @account.save
      complete_pairing!(@account, auth_session)
    else
      redirect_to new_account_path, alert: @account.errors.full_messages.join(", ")
    end
  rescue ActiveRecord::RecordNotUnique
    # L16: find_or_initialize_by + save races another request pairing the
    # same key (double poll / second tab) — reload the row the other
    # request created instead of 500ing, and finish pairing against it.
    @account = current_user.accounts.find_by!(pubkey_hex: user_pubkey)
    complete_pairing!(@account, auth_session)
  end

  def edit
  end

  def update
    if @account.update(account_params)
      redirect_to @account, notice: "Account updated."
    else
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    @account.destroy
    redirect_to accounts_path, notice: "Account removed."
  end

  def refresh_profile
    # H11/M22: this used to fetch inline (blocking the request for seconds)
    # and always claimed success regardless of outcome. Now it's honest —
    # the job runs in the background and the message says exactly that.
    FetchAccountProfileJob.perform_later(@account.id)
    redirect_to settings_account_path(@account), notice: "Refreshing profile from relays in the background — reload in a few seconds to see changes."
  end

  def refresh_relays
    FetchRelayListJob.perform_later(@account.id)
    redirect_to settings_account_path(@account), notice: "Refreshing relay list in the background — reload in a few seconds to see changes."
  end

  def re_pair
    # ?reason=messaging swaps the copy for the NIP-17 permission grant, which
    # needs two extra steps the normal re-pair does not (see the view).
    @messaging_repair = params[:reason] == "messaging"
    pending_pairing_session&.consume!
    @connect_data = Nostr::AuthService.new.generate_connect_uri
    session[:account_pairing_session_id] = @connect_data[:session_id]
    Nip46SupervisorJob.ensure_running
    @qr_code = RQRCode::QRCode.new(@connect_data[:uri])
  end

  def re_pair_poll
    session_id = session[:account_pairing_session_id]
    return render json: { paired: false, error: "No pending session" } if session_id.blank?

    auth_session = NostrAuthSession.active.find_by(session_id: session_id)
    # No active session left under this id means it expired (or was consumed/
    # never existed) — say so explicitly so the poller stops instead of
    # spinning on {paired:false} forever (H9).
    return render json: { paired: false, expired: true } if auth_session.nil?

    if auth_session.authenticated?
      if auth_session.authenticated_user_pubkey != @account.pubkey_hex
        auth_session.consume!
        session.delete(:account_pairing_session_id)
        render json: { paired: false, error: "Re-pair aborted: signer returned a different Nostr identity (#{auth_session.authenticated_user_pubkey[0..15]}…) than this account (#{@account.pubkey_hex[0..15]}…)." }
        return
      end

      # A save failure here used to escape as an HTML 422, which the poller then
      # tried to JSON.parse — so the real reason never reached the user and the
      # poll just spun. Answer in JSON whatever happens.
      unless @account.apply_signer(auth_session).save
        render json: { paired: false, error: "Could not save the signer: #{@account.errors.full_messages.to_sentence}" }
        return
      end

      auth_session.consume!
      session.delete(:account_pairing_session_id)
      render json: { paired: true, redirect_url: account_path(@account) }
    else
      render json: { paired: false, auth_url: auth_session&.auth_url }
    end
  end

  def pair_poll
    session_id = session[:account_pairing_session_id]
    return render json: { paired: false, error: "No pending session" } if session_id.blank?

    auth_session = NostrAuthSession.active.find_by(session_id: session_id)
    # No active session left under this id means it expired (or was consumed/
    # never existed) — say so explicitly so the poller stops instead of
    # spinning on {paired:false} forever (H9).
    if auth_session.nil?
      render json: { paired: false, expired: true }
    elsif auth_session.authenticated?
      render json: { paired: true, pubkey: auth_session.authenticated_user_pubkey }
    else
      render json: { paired: false, auth_url: auth_session.auth_url }
    end
  end

  private

  def set_account
    @account = current_user.accounts.find(params[:id])
  end

  def account_params
    params.require(:account).permit(:display_name, :username, :about, :picture_url, :personality, :blossom_server)
  end

  def pending_pairing_session
    NostrAuthSession.active.find_by(session_id: session[:account_pairing_session_id])
  end

  # Rebuild the nostrconnect:// URI for an already-persisted pairing session
  # (mirrors Nostr::AuthService#generate_connect_uri, minus creating new key
  # material) so `new` can redisplay the same QR instead of issuing a new one.
  def connect_data_from_session(auth_session)
    relay_urls = auth_session.relay_urls
    relay_params = relay_urls.map { |r| "relay=#{CGI.escape(r)}" }.join("&")
    canonical_url = Nostr::AuthService.new.canonical_url
    metadata = "secret=#{auth_session.secret}&name=#{CGI.escape('Emanator')}" \
               "&perms=#{CGI.escape(Nostr::AuthService::PERMISSIONS)}&url=#{CGI.escape(canonical_url)}"

    {
      uri: "nostrconnect://#{auth_session.temp_pubkey}?#{relay_params}&#{metadata}",
      session_id: auth_session.session_id,
      relay_urls: relay_urls
    }
  end

  # H11: profile + relay-list fetches are blocking relay round-trips (worst
  # case ~40s combined) — never do them inline in the pairing request.
  def complete_pairing!(account, auth_session)
    auth_session.consume!
    session.delete(:account_pairing_session_id)
    FetchAccountProfileJob.perform_later(account.id)
    FetchRelayListJob.perform_later(account.id)
    redirect_to account, notice: "Account paired! Fetching profile and relay list in the background."
  end

  def pairing_rate_limited
    redirect_to accounts_path, alert: "Too many pairing attempts — please wait a minute and try again."
  end

  def fetch_recent_interactions
    fetcher = Nostr::InteractionsFetcher.new
    interactions = fetcher.fetch_for_account(@account, since: 7.days.ago, limit: 10)
    fetcher.enrich_with_profiles(interactions)
    fetcher.enrich_with_original_posts(interactions, [@account])
    interactions
  rescue StandardError => e
    Rails.logger.warn("Failed to fetch interactions for account #{@account.id}: #{e.message}")
    []
  end

  def fetch_recent_events
    Rails.cache.fetch("account_events_#{@account.id}", expires_in: 5.minutes) do
      fetcher = Nostr::EventFetcher.new
      fetcher.fetch(@account.pubkey_hex, kinds: [1], limit: 20, since: 30.days.ago)
    end
  end
end
