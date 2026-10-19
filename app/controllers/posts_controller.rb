# frozen_string_literal: true

class PostsController < ApplicationController
  include ActionView::Helpers::TextHelper
  before_action :set_post, only: [ :show, :edit, :update, :destroy, :schedule, :sign, :retry_sign, :retry_publish, :rebroadcast, :cancel, :reschedule ]
  before_action :set_account, only: [ :new, :create ]

  # How far ahead the schedule screen's "Soon" button sets the publish time:
  # enough to approve the signature(s) in Amber before it comes due.
  SOON_MINUTES = 7

  # 300 posts across 19 identities used to arrive as one unfiltered, unsorted
  # stream — there was no way to answer "what failed?" or "what is queued for
  # Ember?" without reading the whole list.
  def index
    @accounts = current_user.accounts.order(Arel.sql("LOWER(COALESCE(display_name, username, npub))"))
    listing = Posts::Listing.new(current_user, account: params[:account], status: params[:status])
    @account_filter = listing.account_filter
    @status_filter = listing.status_filter
    @short_only = listing.short_only?
    @failed_here = listing.failed_here
    @posts = listing.page(params[:page])
  end

  # Clear out everything that never went out.
  #
  # A failed post is usually one whose moment has passed — a note scheduled for
  # March is not going to be retried in September. There was no way to act on
  # them in bulk, so a backlog of dead posts sat in the dashboard's alarm
  # section permanently, which is how an alarm stops meaning anything.
  def discard_failed
    count = Post.discard_failed_for!(current_user, account_id: params[:account])

    redirect_back fallback_location: dashboard_path,
                  notice: t("posts.flash.discarded", count: count)
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
    # Nothing links to this action with reply_to_event_id/etc. params — the
    # inline-reply flow (inline_reply_controller.js) posts straight to
    # #create with a JSON body instead, so there's no reply-prefill branch
    # to run here (the reply-prefill branch that used to live here was dead).
    @post = @account.posts.build(event_kind: 1)
  end

  def create
    @post = @account.posts.build(post_params)
    @post.status = :draft

    if @post.save
      if @post.is_reply?
        # H15: without a paired signer the reply can never be signed — say so
        # now instead of parking it in "Signing in progress..." forever.
        unless @post.account.has_signer?
          message = t("posts.flash.reply_no_signer", name: @post.account.display_name_or_npub)
          respond_to do |format|
            format.html { redirect_to re_pair_account_path(@post.account), alert: message }
            format.json { render json: { success: false, error: message, post_id: @post.id }, status: :unprocessable_entity }
          end
          return
        end

        @post.start_reply_signing!

        respond_to do |format|
          format.html { redirect_to @post, notice: t("posts.flash.reply_created") }
          format.json { render json: { success: true, post_id: @post.id, message: t("posts.flash.signing") } }
        end
      else
        respond_to do |format|
          # The composer already shows the post; go straight to scheduling
          # rather than a read-only page whose only real action is "Schedule".
          format.html { redirect_to schedule_post_path(@post), notice: t("posts.flash.saved_as_draft") }
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
    redirect_to @post, alert: t("posts.flash.cannot_edit") unless @post.can_edit?
  end

  def update
    unless @post.can_edit?
      redirect_to @post, alert: t("posts.flash.cannot_edit")
      return
    end

    outcome = @post.apply_edit!(post_params)
    if outcome
      notice = outcome == :invalidated ? t("posts.flash.updated_signature_discarded") : t("posts.flash.updated")
      redirect_to (@post.can_schedule? ? schedule_post_path(@post) : @post), notice: notice
    else
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    @post.destroy
    redirect_to account_posts_path(@post.account), notice: t("posts.flash.deleted")
  end

  def schedule
    unless @post.can_schedule?
      redirect_to @post, alert: t("posts.flash.cannot_schedule")
      return
    end

    load_schedule_form
  end

  def sign
    # I5: never re-sign a post that has moved past the schedulable states.
    unless @post.can_schedule?
      redirect_to @post, alert: t("posts.flash.cannot_schedule_status", status: helpers.status_label(@post.status).downcase)
      return
    end

    # H15: without a paired signer nothing can ever sign this post.
    unless @post.account.has_signer?
      redirect_to re_pair_account_path(@post.account),
                  alert: t("posts.flash.post_no_signer_pair_first", name: @post.account.display_name_or_npub)
      return
    end

    # H8: a post with a blank/garbled time would become "scheduled" but never
    # publish — the enqueue query never matches a NULL scheduled_at.
    parsed_at = Posts::Scheduler.parse_time(params[:scheduled_at], params[:timezone].presence || current_user.timezone)
    if parsed_at.nil? && params[:scheduled_at].present?
      @schedule_error = t("posts.flash.invalid_date_time")
      return render_schedule_error
    end

    result = Posts::Scheduler.new(@post).schedule(
      scheduled_at: parsed_at,
      repost_account_ids: params[:repost_account_ids] || [],
      max_delay_hours: params[:max_delay_hours]
    )
    unless result.ok?
      @schedule_error = result.error
      return render_schedule_error
    end

    notice = t("posts.flash.signing_in_progress")
    notice += " #{t("posts.flash.reposts_scheduled", count: result.reposts_scheduled)}" if result.reposts_scheduled > 0
    notice += " #{t("posts.flash.reposts_skipped", count: result.reposts_skipped)}" if result.reposts_skipped > 0
    redirect_to @post, notice: notice
  end

  # There is deliberately no #publish_now for a post. A scheduled post is signed
  # with created_at == scheduled_at, so publishing it ahead of that time puts a
  # future-dated event on the wire, which strict relays reject. Once the time has
  # passed the post has already been published, so the action could only ever run
  # in the case that cannot work. Use Reschedule (re-signs) to move a post earlier.

  def retry_sign
    unless @post.can_retry_sign?
      respond_to do |format|
        format.html { redirect_to @post, alert: t("posts.flash.not_awaiting_signature") }
        format.json { render json: { success: false, error: t("posts.flash.not_awaiting_signature") }, status: :unprocessable_entity }
      end
      return
    end

    # H15: without a paired signer the job no-ops and the post would sit at
    # "Waiting for signature…" until the sweeper gives up 20 minutes later.
    # Say what is actually wrong and link to re-pairing instead.
    unless @post.account.has_signer?
      message = t("posts.flash.post_no_signer", name: @post.account.display_name_or_npub)
      respond_to do |format|
        format.html do
          redirect_to re_pair_account_path(@post.account),
                      alert: "#{message} #{t("posts.flash.pair_signer_to_continue")}"
        end
        format.json { render json: { success: false, error: message }, status: :unprocessable_entity }
      end
      return
    end

    @post.retry_signing!

    respond_to do |format|
      format.html { redirect_to @post, notice: t("posts.flash.retrying_signature") }
      format.json { render json: { success: true, status: @post.status } }
    end
  end

  def retry_publish
    # Nothing was signed, so there is nothing to publish yet: sign it first.
    return retry_sign if !@post.can_retry_publish? && @post.can_retry_sign?

    unless @post.can_retry_publish?
      redirect_to @post, alert: t("posts.flash.cannot_retry_publish")
      return
    end

    notice = @post.retry_publishing! == :sign ? t("posts.flash.resigning_stale") : t("posts.flash.retrying_publish")
    redirect_to @post, notice: notice
  end

  def rebroadcast
    unless @post.can_rebroadcast?
      redirect_to @post, alert: t("posts.flash.cannot_rebroadcast")
      return
    end

    RebroadcastPostJob.perform_later(@post.id)
    redirect_to @post, notice: t("posts.flash.rebroadcasting")
  end

  def cancel
    unless @post.can_cancel?
      redirect_to @post, alert: t("posts.flash.cannot_cancel")
      return
    end

    @post.cancel!
    redirect_to @post, notice: t("posts.flash.cancelled")
  end

  def reschedule
    unless @post.can_reschedule?
      redirect_to @post, alert: t("posts.flash.cannot_reschedule")
      return
    end

    repost_account_ids = @post.reschedule_reset!
    redirect_to schedule_post_path(@post, repost_account_ids: repost_account_ids),
                notice: t("posts.flash.pick_new_time")
  end

  private

  def load_schedule_form
    @scheduler = Scheduling::SchedulerService.new(timezone: current_user.timezone)
    @suggested_time = @scheduler.suggest_next_slot(@post.account)
    @other_accounts = current_user.accounts.where.not(id: @post.account_id)
    @existing_reposts = @post.reposts.includes(:account)
    @preselected_repost_ids = (params[:repost_account_ids] || []).map(&:to_i)
  end

  # H8: re-render the schedule form with an inline error.
  def render_schedule_error
    load_schedule_form
    render :schedule, status: :unprocessable_entity
  end

  def set_post
    @post = Post.joins(:account)
      .where(accounts: { user_id: current_user.id })
      .find(params[:id])
    @account = @post.account
  end

  def set_account
    @account = current_user.accounts.find(params[:account_id])
  end

  def post_params
    params.require(:post).permit(:content, :event_kind, :scheduled_at,
                                  :reply_to_event_id, :reply_to_pubkey, :root_event_id, :is_reply)
  end
end
