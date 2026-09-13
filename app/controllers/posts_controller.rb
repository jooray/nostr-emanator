# frozen_string_literal: true

class PostsController < ApplicationController
  include ActionView::Helpers::TextHelper
  before_action :set_post, only: [:show, :edit, :update, :destroy, :schedule, :sign, :retry_sign, :retry_publish, :rebroadcast, :cancel, :reschedule]
  before_action :set_account, only: [:new, :create]

  # 300 posts across 19 identities used to arrive as one unfiltered, unsorted
  # stream — there was no way to answer "what failed?" or "what is queued for
  # Ember?" without reading the whole list.
  def index
    @accounts = current_user.accounts.order(Arel.sql("LOWER(COALESCE(display_name, username, npub))"))
    @account_filter = params[:account].presence
    @status_filter = params[:status].presence

    scope = Post.joins(:account)
                .where(accounts: { user_id: current_user.id })
                .includes(:account, :reposts)

    scope = scope.where(account_id: @account_filter) if @account_filter
    # "short" is not a status — it is a delivery grade, and publish_results is
    # JSON, so it narrows to published here and is filtered in Ruby below.
    scope =
      case @status_filter
      when "short" then scope.where(status: :published)
      when nil, "all" then scope
      else scope.where(status: @status_filter)
      end

    scope = scope.order(created_at: :desc)
    @short_only = @status_filter == "short"

    # Reposts belong in these two lists, because the station-status readings
    # count them. The rail said "2 never went out" and this list said "No posts
    # match this filter" — both were right about their own query and the reading
    # was unreachable, which is the one thing a reading that links to a list may
    # never be. A failed repost is a real failure: that identity never reposted
    # the note, and nothing else in the app was going to say so.
    #
    # Only these two filters merge. The readings count exactly these states, and
    # folding reposts into "Published" or "All" would reshape lists nobody
    # reported a problem with.
    reposts = reposts_for_filter

    @failed_here = failed_here_count

    @posts =
      if @short_only
        Kaminari.paginate_array(scope.select(&:delivery_alarming?)).page(params[:page])
      elsif reposts.any?
        merged = (scope.to_a + reposts).sort_by { |record| record.created_at }.reverse
        Kaminari.paginate_array(merged).page(params[:page])
      else
        scope.page(params[:page])
      end
  end

  # Clear out everything that never went out.
  #
  # A failed post is usually one whose moment has passed — a note scheduled for
  # March is not going to be retried in September. There was no way to act on
  # them in bulk, so a backlog of dead posts sat in the dashboard's alarm
  # section permanently, which is how an alarm stops meaning anything.
  def discard_failed
    scope = Post.joins(:account).where(accounts: { user_id: current_user.id }, posts: { status: :failed })
    scope = scope.where(account_id: params[:account]) if params[:account].present?

    # Reposts are counted by the same reading and listed beside the posts, so
    # they have to be cleared by the same button. Discarding only the posts left
    # the alarm lit with nothing under it to act on.
    repost_scope = Repost.joins(:account).where(accounts: { user_id: current_user.id }, reposts: { status: :failed })
    repost_scope = repost_scope.where(account_id: params[:account]) if params[:account].present?

    count = scope.count + repost_scope.count
    scope.destroy_all
    repost_scope.destroy_all

    redirect_back fallback_location: dashboard_path,
                  notice: "Discarded #{pluralize(count, 'post')} that never went out."
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
          message = "#{@post.account.display_name_or_npub} has no paired signer, so this reply cannot be signed. Pair the account first."
          respond_to do |format|
            format.html { redirect_to re_pair_account_path(@post.account), alert: message }
            format.json { render json: { success: false, error: message, post_id: @post.id }, status: :unprocessable_entity }
          end
          return
        end

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

        SignPostJob.perform_later(@post.id)

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

    content_changed = post_params.key?(:content) && @post.content != post_params[:content]

    # Save version history
    if content_changed
      history = @post.version_history || []
      history << { content: @post.content, changed_at: Time.current.iso8601 }
      @post.version_history = history
    end

    # C5: the unsigned event still carries the OLD text. Editing while a
    # signing request is in flight would otherwise publish stale content.
    invalidated = content_changed && @post.awaiting_signature?
    if invalidated
      @post.assign_attributes(status: :draft, unsigned_event: nil, signed_event: nil, event_id: nil)
    end

    if @post.update(post_params)
      if invalidated
        # Repost events embed the original event, so they are stale too.
        @post.reposts.update_all(
          status: Repost.statuses[:pending_signature],
          unsigned_event: nil, signed_event: nil, event_id: nil,
          updated_at: Time.current
        )
      end

      notice = if invalidated
        "Post updated. The pending signature was discarded because the content changed — schedule and sign it again."
      else
        "Post updated."
      end
      redirect_to @post, notice: notice
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

    load_schedule_form
  end

  def sign
    # I5: never re-sign a post that has moved past the schedulable states.
    unless @post.can_schedule?
      redirect_to @post, alert: "Cannot schedule this post (it is #{helpers.status_label(@post.status).downcase})."
      return
    end

    # H15: without a paired signer nothing can ever sign this post.
    unless @post.account.has_signer?
      redirect_to re_pair_account_path(@post.account),
                  alert: "#{@post.account.display_name_or_npub} has no paired signer, so this post cannot be signed. Pair the account first."
      return
    end

    repost_account_ids = params[:repost_account_ids] || []
    # I6/L11: keep the repost delay window sane (1 hour .. 1 year).
    max_delay_hours = (params[:max_delay_hours] || 24).to_i.clamp(1, Scheduling::RepostSchedulerService::MAX_DELAY_HOURS)

    # H8: a post with a blank/garbled time would become "scheduled" but never
    # publish — the enqueue query never matches a NULL scheduled_at.
    parsed_at = parse_scheduled_at(params[:scheduled_at], params[:timezone])
    if parsed_at.nil?
      @schedule_error = params[:scheduled_at].blank? ? "Pick a date and time to publish this post." : "That date and time could not be understood. Pick a valid date and time."
      return render_schedule_error
    elsif parsed_at <= Time.current
      @schedule_error = "The publish time must be in the future."
      return render_schedule_error
    end

    @post.update!(scheduled_at: parsed_at)

    # Build unsigned event for the original post
    signer = Nostr::EventSignerService.new
    # build_unsigned_note (not build_unsigned_event) so mentions and quoted
    # notes in the text become p/q tags — see Nostr::ContentTagger.
    unsigned = signer.build_unsigned_note(
      content: @post.content,
      kind: @post.event_kind,
      pubkey: @post.account.pubkey_hex,
      created_at: @post.scheduled_at || Time.current,
      # Scheduling is user-initiated and happens once; if a quoted note's author
      # is not already cached this is the last chance to look it up.
      allow_fetch: true
    )
    @post.update!(unsigned_event: unsigned, status: :awaiting_signature)

    # Schedule reposts
    if repost_account_ids.any?
      Scheduling::RepostSchedulerService.new.schedule_reposts(@post, repost_account_ids, max_delay_hours: max_delay_hours)
    end

    # Build unsigned events for reposts
    @post.reposts.pending_signature.each do |repost|
      # H15: a repost account with no signer can never be signed — fail it now
      # rather than stranding it in awaiting_signature.
      unless repost.account.has_signer?
        repost.update!(status: :failed, publish_results: { "error" => "No paired signer for this account" })
        next
      end

      unsigned_repost = signer.build_unsigned_repost(
        original_event: unsigned,
        pubkey: repost.account.pubkey_hex,
        created_at: repost.scheduled_at || Time.current
      )
      repost.update!(unsigned_event: unsigned_repost, status: :awaiting_signature)
    end

    SignPostJob.perform_later(@post.id)

    reposts_count = @post.reposts.awaiting_signature.count
    skipped_count = @post.reposts.failed.count
    notice = "Signing in progress."
    notice += " #{reposts_count} #{'repost'.pluralize(reposts_count)} scheduled." if reposts_count > 0
    notice += " #{skipped_count} #{'repost'.pluralize(skipped_count)} skipped (account has no paired signer)." if skipped_count > 0
    redirect_to @post, notice: notice
  end

  # There is deliberately no #publish_now for a post. A scheduled post is signed
  # with created_at == scheduled_at, so publishing it ahead of that time puts a
  # future-dated event on the wire, which strict relays reject. Once the time has
  # passed the post has already been published, so the action could only ever run
  # in the case that cannot work. Use Reschedule (re-signs) to move a post earlier.

  def retry_sign
    unless (@post.awaiting_signature? || (@post.failed? && @post.signed_event.blank?)) && @post.unsigned_event.present?
      respond_to do |format|
        format.html { redirect_to @post, alert: "Post is not awaiting signature." }
        format.json { render json: { success: false, error: "Post is not awaiting signature." }, status: :unprocessable_entity }
      end
      return
    end

    # H15: without a paired signer the job no-ops and the post would sit at
    # "Waiting for signature…" until the sweeper gives up 20 minutes later.
    # Say what is actually wrong and link to re-pairing instead.
    unless @post.account.has_signer?
      message = "#{@post.account.display_name_or_npub} has no paired signer, so this post cannot be signed."
      respond_to do |format|
        format.html do
          redirect_to re_pair_account_path(@post.account),
                      alert: "#{message} Pair a signer to continue."
        end
        format.json { render json: { success: false, error: message }, status: :unprocessable_entity }
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

  # The two states whose station reading counts reposts as well as posts.
  MERGED_REPOST_STATUSES = {
    "failed" => %i[failed],
    "awaiting_signature" => %i[awaiting_signature pending_signature]
  }.freeze

  def reposts_for_filter
    statuses = MERGED_REPOST_STATUSES[@status_filter]
    return [] unless statuses

    Repost.joins(:account)
          .where(accounts: { user_id: current_user.id }, reposts: { status: statuses })
          .then { |s| @account_filter ? s.where(account_id: @account_filter) : s }
          .includes(:account, :post)
          .to_a
  end

  # Offered right where the failures are listed, scoped to the account filter in
  # view so it can never clear more than what is on screen — which now means
  # counting the reposts it also clears.
  def failed_here_count
    return 0 unless @status_filter == "failed"

    scoped = lambda do |relation|
      @account_filter ? relation.where(account_id: @account_filter) : relation
    end

    scoped.call(Post.joins(:account).where(accounts: { user_id: current_user.id }, posts: { status: :failed })).count +
      scoped.call(Repost.joins(:account).where(accounts: { user_id: current_user.id }, reposts: { status: :failed })).count
  end

  def parse_scheduled_at(value, timezone_param)
    return nil if value.blank?

    timezone_name = timezone_param.presence || current_user.timezone || "UTC"
    tz = ActiveSupport::TimeZone[timezone_name] || Time.zone
    tz.parse(value.to_s)
  rescue ArgumentError, TypeError
    nil
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
