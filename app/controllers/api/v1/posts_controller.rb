# frozen_string_literal: true

module Api
  module V1
    # Posts, scheduling and the recovery actions. Each action calls the same
    # model/service operation as PostsController, and answers with the post as
    # it now stands so the app can redraw without a second request.
    class PostsController < BaseController
      before_action :set_post, except: %i[index create discard_failed]

      def index
        listing = Posts::Listing.new(current_user, account: params[:account_id], status: params[:status])
        page = listing.page(page_param)
        render json: {
          items: page.map { |record| serializer.row(record) },
          failed_here: listing.failed_here,
          pagination: pagination(page)
        }
      end

      def show
        render json: { post: serializer.post(@post, detail: true) }
      end

      # A draft, or a reply (which signs at once, like the web's inline reply).
      def create
        account = current_user.accounts.find(params[:account_id] || params.dig(:post, :account_id))
        post = account.posts.build(post_params)
        post.status = :draft
        return render_error(post.errors.full_messages.join(", ")) unless post.save

        if post.is_reply?
          # H15: without a paired signer the reply could never be signed.
          unless account.has_signer?
            return render_error(I18n.t("posts.flash.reply_no_signer", name: account.display_name_or_npub),
                                code: "no_signer", post_id: post.id)
          end
          post.start_reply_signing!
          return render json: { post: serializer.post(post.reload, detail: true), message: I18n.t("posts.flash.signing") }, status: :created
        end

        render json: { post: serializer.post(post, detail: true), message: I18n.t("posts.flash.saved_as_draft") }, status: :created
      end

      def update
        return render_error(I18n.t("posts.flash.cannot_edit"), code: "cannot_edit") unless @post.can_edit?

        outcome = @post.apply_edit!(post_params)
        return render_error(@post.errors.full_messages.join(", ")) unless outcome

        message = outcome == :invalidated ? I18n.t("posts.flash.updated_signature_discarded") : I18n.t("posts.flash.updated")
        render json: { post: serializer.post(@post.reload, detail: true), message: message }
      end

      def destroy
        @post.destroy
        head :no_content
      end

      # What the schedule screen needs: a suggested slot and the accounts that
      # could repost.
      def schedule_options
        scheduler = Scheduling::SchedulerService.new(timezone: current_user.timezone)
        render json: {
          suggested_at: serializer.time(scheduler.suggest_next_slot(@post.account)),
          soon_minutes: ::PostsController::SOON_MINUTES,
          default_max_delay_hours: Scheduling::RepostSchedulerService::DEFAULT_MAX_DELAY_HOURS,
          max_delay_hours: Scheduling::RepostSchedulerService::MAX_DELAY_HOURS,
          repost_accounts: current_user.accounts.where.not(id: @post.account_id).order(:created_at).map { |a| serializer.account_mini(a) },
          existing_repost_account_ids: @post.reposts.pluck(:account_id)
        }
      end

      # Sign & schedule (the web's "Sign & Schedule" button).
      def schedule
        parsed_at = Posts::Scheduler.parse_time(params[:scheduled_at], params[:timezone].presence || current_user.timezone)
        if parsed_at.nil? && params[:scheduled_at].present?
          return render_error(I18n.t("posts.flash.invalid_date_time"), code: "invalid_time")
        end

        result = Posts::Scheduler.new(@post).schedule(
          scheduled_at: parsed_at,
          repost_account_ids: params[:repost_account_ids] || [],
          max_delay_hours: params[:max_delay_hours]
        )
        return render_error(result.error, code: "cannot_schedule") unless result.ok?

        message = I18n.t("posts.flash.signing_in_progress")
        message += " #{I18n.t("posts.flash.reposts_scheduled", count: result.reposts_scheduled)}" if result.reposts_scheduled > 0
        message += " #{I18n.t("posts.flash.reposts_skipped", count: result.reposts_skipped)}" if result.reposts_skipped > 0
        respond_with_post(message)
      end

      def retry_sign
        return render_error(I18n.t("posts.flash.not_awaiting_signature")) unless @post.can_retry_sign?
        unless @post.account.has_signer?
          return render_error(I18n.t("posts.flash.post_no_signer", name: @post.account.display_name_or_npub), code: "no_signer")
        end

        @post.retry_signing!
        respond_with_post(I18n.t("posts.flash.retrying_signature"))
      end

      def retry_publish
        return retry_sign if !@post.can_retry_publish? && @post.can_retry_sign?
        return render_error(I18n.t("posts.flash.cannot_retry_publish")) unless @post.can_retry_publish?

        outcome = @post.retry_publishing!
        respond_with_post(I18n.t(outcome == :sign ? "posts.flash.resigning_stale" : "posts.flash.retrying_publish"))
      end

      def rebroadcast
        return render_error(I18n.t("posts.flash.cannot_rebroadcast")) unless @post.can_rebroadcast?

        RebroadcastPostJob.perform_later(@post.id)
        respond_with_post(I18n.t("posts.flash.rebroadcasting"))
      end

      def cancel
        return render_error(I18n.t("posts.flash.cannot_cancel")) unless @post.can_cancel?

        @post.cancel!
        respond_with_post(I18n.t("posts.flash.cancelled"))
      end

      # Back to a draft, remembering which accounts were reposting so the
      # schedule screen can pre-select them.
      def reschedule
        return render_error(I18n.t("posts.flash.cannot_reschedule")) unless @post.can_reschedule?

        repost_account_ids = @post.reschedule_reset!
        render json: { post: serializer.post(@post.reload, detail: true), repost_account_ids: repost_account_ids,
                       message: I18n.t("posts.flash.pick_new_time") }
      end

      def discard_failed
        count = Post.discard_failed_for!(current_user, account_id: params[:account_id])
        render json: { discarded: count, message: I18n.t("posts.flash.discarded", count: count) }
      end

      private

      def set_post
        @post = Post.joins(:account).where(accounts: { user_id: current_user.id }).find(params[:id])
      end

      def post_params
        params.require(:post).permit(:content, :reply_to_event_id, :reply_to_pubkey, :root_event_id, :is_reply)
      end

      def respond_with_post(message)
        render json: { post: serializer.post(@post.reload, detail: true), message: message }
      end
    end
  end
end
