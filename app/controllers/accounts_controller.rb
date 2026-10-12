# frozen_string_literal: true

class AccountsController < ApplicationController
  before_action :set_account, only: [ :show, :edit, :update, :destroy, :refresh_profile, :refresh_relays, :re_pair, :re_pair_poll, :settings, :recent_events, :recent_interactions, :profile, :update_profile, :profile_status ]

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
    return redirect_to(accounts_path, alert: account_limit_message) unless Billing.can_add_account?(current_user)

    @account = current_user.accounts.build

    # Reuse an in-progress pairing session (e.g. a second tab, or a reload of
    # this same tab) instead of consuming it — killing an active session out
    # from under a QR the user already scanned in another tab strands that
    # tab's poller forever (L28).
    existing_session = pending_pairing_session
    if existing_session
      Nip46SupervisorJob.ensure_running
      @connect_data = Accounts::Pairing.connect_data(existing_session)
    else
      @connect_data = Accounts::Pairing.start
      session[:account_pairing_session_id] = @connect_data[:session_id]
    end

    @qr_code = RQRCode::QRCode.new(@connect_data[:uri])
  end

  def create
    result = Accounts::Pairing.new(current_user, session[:account_pairing_session_id]).complete_new

    case result.status
    when :paired
      session.delete(:account_pairing_session_id)
      redirect_to result.account, notice: t("accounts.paired_notice")
    when :over_limit
      redirect_to accounts_path, alert: result.error
    when :failed
      redirect_to new_account_path, alert: result.error
    else
      redirect_to new_account_path, alert: t("accounts.create.session_expired")
    end
  end

  def edit
  end

  def update
    if @account.update(account_params)
      redirect_to @account, notice: t(".updated")
    else
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    @account.destroy
    redirect_to accounts_path, notice: t(".removed")
  end

  # Nostr profile (kind 0) editor. Amber has no profile editor of its own, so
  # this is the only place a paired account's published profile can be changed.
  def profile
    @profile = current_profile_fields
    @pending_update = @account.profile_updates.order(:created_at).last
  end

  def update_profile
    unless @account.profile_editing_capable?
      redirect_to profile_account_path(@account),
                  alert: t(".needs_re_pair")
      return
    end

    ProfileUpdate.sweep_stale!

    update = @account.profile_updates.create!(
      user: current_user,
      edits: profile_edit_params,
      status: "pending"
    )
    PublishProfileJob.perform_later(update.id)

    render json: { ok: true, id: update.id, poll_url: profile_status_account_path(@account, update_id: update.id) }
  end

  # Polled by the editor while the user approves in their signer.
  def profile_status
    update = @account.profile_updates.find_by(id: params[:update_id])
    return render json: { status: "failed", error: t(".gone") } unless update

    render json: {
      status: update.display_status,
      step: update.step,
      error: update.display_error
    }
  end

  def refresh_profile
    # H11/M22: this used to fetch inline (blocking the request for seconds)
    # and always claimed success regardless of outcome. Now it's honest —
    # the job runs in the background and the message says exactly that.
    FetchAccountProfileJob.perform_later(@account.id)
    redirect_to settings_account_path(@account), notice: t(".notice")
  end

  def refresh_relays
    FetchRelayListJob.perform_later(@account.id)
    redirect_to settings_account_path(@account), notice: t(".notice")
  end

  def re_pair
    # ?reason=messaging swaps the copy for the NIP-17 permission grant, which
    # needs two extra steps the normal re-pair does not (see the view).
    @messaging_repair = params[:reason] == "messaging"
    pending_pairing_session&.consume!
    @connect_data = Accounts::Pairing.start
    session[:account_pairing_session_id] = @connect_data[:session_id]
    @qr_code = RQRCode::QRCode.new(@connect_data[:uri])
  end

  def re_pair_poll
    session_id = session[:account_pairing_session_id]
    return render json: { paired: false, error: t("accounts.no_pending_session") } if session_id.blank?

    result = Accounts::Pairing.new(current_user, session_id).complete_re_pair(@account)
    # Every outcome answers in JSON: an HTML error page here used to reach the
    # poller, which then tried to JSON.parse it — so the real reason never
    # reached the user and the poll just spun. No active session left under
    # this id means it expired — say so explicitly so the poller stops (H9).
    case result.status
    when :paired
      session.delete(:account_pairing_session_id)
      render json: { paired: true, redirect_url: account_path(@account) }
    when :expired
      render json: { paired: false, expired: true }
    when :pending
      render json: { paired: false, auth_url: result.auth_url }
    else
      session.delete(:account_pairing_session_id) if Accounts::Pairing.active_session(session_id).nil?
      render json: { paired: false, error: result.error }
    end
  end

  def pair_poll
    session_id = session[:account_pairing_session_id]
    return render json: { paired: false, error: t("accounts.no_pending_session") } if session_id.blank?

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

  def account_limit_message
    t("billing.account_limit", limit: Billing::FREE_ACCOUNT_LIMIT)
  end

  # Only the fields the editor offers. Everything else already in the published
  # profile is preserved by ProfilePublisherService#merge_content — this list
  # governs what we are willing to *change*, not what the profile may contain.
  def profile_edit_params
    params.require(:profile)
          .permit(*Nostr::ProfilePublisherService::EDITABLE_FIELDS)
          .to_h
  end

  # Read the live profile so the form starts from what is actually published,
  # not from our four cached columns — editing from the cache and publishing
  # would drop every field we do not model.
  def current_profile_fields
    event = Nostr::ProfileFetcher.new.fetch_raw_event(@account.pubkey_hex)
    return {} unless event

    parsed = JSON.parse(event["content"].to_s)
    parsed.is_a?(Hash) ? parsed : {}
  rescue JSON::ParserError, StandardError => e
    Rails.logger.warn("Could not read profile for account #{@account.id}: #{e.class} - #{e.message}")
    {}
  end

  def set_account
    @account = current_user.accounts.find(params[:id])
  end

  def account_params
    params.require(:account).permit(:display_name, :username, :about, :picture_url, :personality, :blossom_server)
  end

  def pending_pairing_session
    NostrAuthSession.active.find_by(session_id: session[:account_pairing_session_id])
  end

  def pairing_rate_limited
    redirect_to accounts_path, alert: t("accounts.pairing_rate_limited")
  end

  def fetch_recent_interactions
    fetcher = Nostr::InteractionsFetcher.new
    interactions = fetcher.fetch_for_account(@account, since: 7.days.ago, limit: 10)
    fetcher.enrich_with_profiles(interactions)
    fetcher.enrich_with_original_posts(interactions, [ @account ])
    interactions
  rescue StandardError => e
    Rails.logger.warn("Failed to fetch interactions for account #{@account.id}: #{e.message}")
    []
  end

  def fetch_recent_events
    Rails.cache.fetch("account_events_#{@account.id}", expires_in: 5.minutes) do
      fetcher = Nostr::EventFetcher.new
      fetcher.fetch(@account.pubkey_hex, kinds: [ 1 ], limit: 20, since: 30.days.ago)
    end
  end
end
