# frozen_string_literal: true

class AccountsController < ApplicationController
  before_action :set_account, only: [:show, :edit, :update, :destroy, :refresh_profile, :refresh_relays, :re_pair, :re_pair_poll, :settings, :recent_events, :recent_interactions]

  def index
    @accounts = current_user.accounts.order(:created_at)
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
    pending_pairing_session&.consume!
    @connect_data = Nostr::AuthService.new.generate_connect_uri
    session[:account_pairing_session_id] = @connect_data[:session_id]
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
    signer_pubkey = auth_session.authenticated_pubkey
    @account = current_user.accounts.find_or_initialize_by(pubkey_hex: user_pubkey)
    @account.assign_attributes(
      npub: Nostr::KeyConverter.hex_to_npub(user_pubkey),
      signer_pubkey: signer_pubkey,
      signer_relay: auth_session.relay_urls.first,
      app_pubkey: auth_session.temp_pubkey,
      app_privkey: auth_session.temp_privkey
    )

    if @account.save
      auth_session.consume!
      session.delete(:account_pairing_session_id)
      fetch_and_update_profile(@account)
      fetch_and_update_relays(@account)
      redirect_to @account, notice: "Account paired successfully!"
    else
      redirect_to new_account_path, alert: @account.errors.full_messages.join(", ")
    end
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
    fetch_and_update_profile(@account)
    redirect_to settings_account_path(@account), notice: "Profile refreshed from relays."
  end

  def refresh_relays
    fetch_and_update_relays(@account)
    redirect_to settings_account_path(@account), notice: "Relay list refreshed."
  end

  def re_pair
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
    if auth_session&.authenticated?
      if auth_session.authenticated_user_pubkey != @account.pubkey_hex
        auth_session.consume!
        session.delete(:account_pairing_session_id)
        render json: { paired: false, error: "Re-pair aborted: signer returned a different Nostr identity (#{auth_session.authenticated_user_pubkey[0..15]}…) than this account (#{@account.pubkey_hex[0..15]}…)." }
        return
      end

      @account.update!(
        signer_pubkey: auth_session.authenticated_pubkey,
        signer_relay: auth_session.relay_urls.first,
        app_pubkey: auth_session.temp_pubkey,
        app_privkey: auth_session.temp_privkey
      )
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
    if auth_session&.authenticated?
      render json: { paired: true, pubkey: auth_session.authenticated_user_pubkey }
    else
      render json: { paired: false, auth_url: auth_session&.auth_url }
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

  def fetch_and_update_profile(account)
    profile = Nostr::ProfileFetcher.new.fetch(account.pubkey_hex)
    if profile
      account.update(
        display_name: profile[:display_name],
        username: profile[:username],
        about: profile[:about],
        picture_url: profile[:picture]
      )
    end
  end

  def fetch_and_update_relays(account)
    relays = Nostr::RelayListFetcher.new.fetch_write_relays(account.pubkey_hex)
    account.update(write_relays: relays) if relays.any?
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
