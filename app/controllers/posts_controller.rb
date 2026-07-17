# frozen_string_literal: true

class PostsController < ApplicationController
  before_action :set_post, only: [:show, :edit, :update, :destroy, :schedule, :sign, :retry_sign, :publish_now, :retry_publish, :rebroadcast, :cancel, :reschedule]
  before_action :set_account, only: [:new, :create]

  def index
    @posts = Post.joins(:account)
      .where(accounts: { user_id: current_user.id })
      .includes(:account, :reposts)
      .order(created_at: :desc)
      .page(params[:page])
  end

  def select_account
    @accounts = current_user.accounts.order(Arel.sql("LOWER(COALESCE(display_name, username, npub))"))
    redirect_to(new_account_post_path(@accounts.first)) and return if @accounts.size == 1
  end

  def show
    respond_to do |format|
      format.html { @reposts = @post.reposts.includes(:account) }
      format.json do
        render json: {
          id: @post.id,
          status: @post.status,
          signed_event_present: @post.signed_event.present?,
          unsigned_event_present: @post.unsigned_event.present?
        }
      end
    end
  end

  def new
    @post = @account.posts.build(event_kind: 1)

    # Pre-fill reply metadata if replying to an interaction
    if params[:reply_to_event_id].present?
      @post.reply_to_event_id = params[:reply_to_event_id]
      @post.reply_to_pubkey = params[:reply_to_pubkey]
      @post.root_event_id = params[:root_event_id]
      @post.is_reply = true
      @reply_context = params[:reply_context]
    end
  end

  def create
    @post = @account.posts.build(post_params)
    @post.status = :draft

    if @post.save
      if @post.is_reply?
        # Replies skip scheduling — build unsigned event and sign immediately
        signer = Nostr::EventSignerService.new
        unsigned = signer.build_unsigned_reply(
          content: @post.content,
          pubkey: @post.account.pubkey_hex,
          created_at: Time.current,
          parent_event_id: @post.reply_to_event_id,
          parent_author_pubkey: @post.reply_to_pubkey,
          root_event_id: @post.root_event_id
        )
        @post.update!(
          unsigned_event: unsigned,
          scheduled_at: Time.current,
          status: :awaiting_signature
        )

        if @post.account.has_signer?
          SignPostJob.perform_later(@post.id)
        end

        respond_to do |format|
          format.html { redirect_to @post, notice: "Reply created. Signing in progress..." }
          format.json { render json: { success: true, post_id: @post.id, message: "Signing..." } }
        end
      else
        respond_to do |format|
          format.html { redirect_to @post, notice: "Post created." }
          format.json { render json: { success: true, post_id: @post.id } }
        end
      end
    else
      @reply_context = params.dig(:post, :reply_context) || params[:reply_context]
      respond_to do |format|
        format.html { render :new, status: :unprocessable_entity }
        format.json { render json: { success: false, error: @post.errors.full_messages.join(", ") }, status: :unprocessable_entity }
      end
    end
  end

  def edit
    redirect_to @post, alert: "Cannot edit this post." unless @post.can_edit?
  end

  def update
    unless @post.can_edit?
      redirect_to @post, alert: "Cannot edit this post."
      return
    end

    # Save version history
    if @post.content != post_params[:content]
      history = @post.version_history || []
      history << { content: @post.content, changed_at: Time.current.iso8601 }
      @post.version_history = history
    end

    if @post.update(post_params)
      redirect_to @post, notice: "Post updated."
    else
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    @post.destroy
    redirect_to account_posts_path(@post.account), notice: "Post deleted."
  end

  def schedule
    unless @post.can_schedule?
      redirect_to @post, alert: "Cannot schedule this post."
      return
    end

    @scheduler = Scheduling::SchedulerService.new(timezone: current_user.timezone)
    @suggested_time = @scheduler.suggest_next_slot(@post.account)
    @other_accounts = current_user.accounts.where.not(id: @post.account_id)
    @existing_reposts = @post.reposts.includes(:account)
    @preselected_repost_ids = (params[:repost_account_ids] || []).map(&:to_i)
  end

  def sign
    scheduled_at = params[:scheduled_at]
    repost_account_ids = params[:repost_account_ids] || []
    max_delay_hours = (params[:max_delay_hours] || 24).to_i

    if scheduled_at.present?
      timezone_name = params[:timezone].presence || current_user.timezone || "UTC"
      tz = ActiveSupport::TimeZone[timezone_name] || Time.zone
      @post.update!(scheduled_at: tz.parse(scheduled_at))
    end

    # Build unsigned event for the original post
    signer = Nostr::EventSignerService.new
    unsigned = signer.build_unsigned_event(
      content: @post.content,
      kind: @post.event_kind,
      pubkey: @post.account.pubkey_hex,
      created_at: @post.scheduled_at || Time.current
    )
    @post.update!(unsigned_event: unsigned, status: :awaiting_signature)

    # Schedule reposts
    if repost_account_ids.any?
      Scheduling::RepostSchedulerService.new.schedule_reposts(@post, repost_account_ids, max_delay_hours: max_delay_hours)
    end

    # Build unsigned events for reposts
    @post.reposts.pending_signature.each do |repost|
      unsigned_repost = signer.build_unsigned_repost(
        original_event: unsigned,
        pubkey: repost.account.pubkey_hex,
        created_at: repost.scheduled_at || Time.current
      )
      repost.update!(unsigned_event: unsigned_repost, status: :awaiting_signature)
    end

    # Enqueue background signing job if account has signer
    if @post.account.has_signer?
      SignPostJob.perform_later(@post.id)
    end

    redirect_to @post, notice: "Signing in progress. #{@post.reposts.count} reposts scheduled."
  end

  def publish_now
    unless @post.can_publish?
      redirect_to @post, alert: "Post is not ready to publish."
      return
    end

    PublishPostJob.perform_later(@post.id)
    @post.update!(status: :publishing)
    redirect_to @post, notice: "Publishing post..."
  end

  def retry_sign
    unless (@post.awaiting_signature? || (@post.failed? && @post.signed_event.blank?)) && @post.unsigned_event.present?
      respond_to do |format|
        format.html { redirect_to @post, alert: "Post is not awaiting signature." }
        format.json { render json: { success: false, error: "Post is not awaiting signature." }, status: :unprocessable_entity }
      end
      return
    end

    @post.update!(status: :awaiting_signature, publish_results: nil) if @post.failed?
    SignPostJob.perform_later(@post.id)

    respond_to do |format|
      format.html { redirect_to @post, notice: "Retrying signature request..." }
      format.json { render json: { success: true, status: @post.status } }
    end
  end

  def retry_publish
    unless @post.can_retry_publish?
      redirect_to @post, alert: "Cannot retry publishing."
      return
    end

    @post.update!(status: :scheduled, publish_results: nil)
    PublishPostJob.perform_later(@post.id)

    @post.reposts.failed.each do |repost|
      repost.update!(status: :scheduled, publish_results: nil)
      PublishRepostJob.perform_later(repost.id)
    end

    redirect_to @post, notice: "Retrying publish..."
  end

  def rebroadcast
    unless @post.can_rebroadcast?
      redirect_to @post, alert: "Cannot rebroadcast this post."
      return
    end

    RebroadcastPostJob.perform_later(@post.id)
    redirect_to @post, notice: "Rebroadcasting to relays..."
  end

  def cancel
    unless @post.can_cancel?
      redirect_to @post, alert: "Cannot cancel this post."
      return
    end

    @post.cancel!
    redirect_to @post, notice: "Post cancelled and returned to draft."
  end

  def reschedule
    unless @post.can_reschedule?
      redirect_to @post, alert: "Cannot reschedule this post."
      return
    end

    repost_account_ids = @post.reschedule_reset!
    redirect_to schedule_post_path(@post, repost_account_ids: repost_account_ids),
                notice: "Pick a new schedule time."
  end

  private

  def set_post
    @post = Post.joins(:account)
      .where(accounts: { user_id: current_user.id })
      .find(params[:id])
  end

  def set_account
    @account = current_user.accounts.find(params[:account_id])
  end

  def post_params
    params.require(:post).permit(:content, :event_kind, :scheduled_at,
                                  :reply_to_event_id, :reply_to_pubkey, :root_event_id, :is_reply)
  end
end
