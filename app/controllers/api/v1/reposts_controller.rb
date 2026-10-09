# frozen_string_literal: true

module Api
  module V1
    # A repost's own recovery actions. Each answers with the parent post, since
    # that is the screen a repost lives on.
    class RepostsController < BaseController
      before_action :set_repost

      def destroy
        return render_error(I18n.t("reposts.flash.cannot_cancel")) unless @repost.can_cancel?

        post = @repost.post
        @repost.destroy
        render json: { post: serializer.post(post.reload, detail: true), message: I18n.t("reposts.flash.cancelled") }
      end

      def retry_sign
        return render_error(I18n.t("reposts.flash.not_awaiting_signature")) unless @repost.can_retry_sign?

        outcome = @repost.retry_signing!
        respond_with_post(outcome == :sign_and_publish ? I18n.t("reposts.flash.retrying_sign_and_publish") : I18n.t("reposts.flash.retrying_sign"))
      end

      def rebroadcast
        return render_error(I18n.t("reposts.flash.cannot_rebroadcast")) unless @repost.can_rebroadcast?

        RebroadcastRepostJob.perform_later(@repost.id)
        respond_with_post(I18n.t("reposts.flash.rebroadcasting"))
      end

      def publish_now
        return render_error(I18n.t("reposts.flash.not_ready")) unless @repost.can_publish_now?
        return render_error(I18n.t("reposts.flash.original_unavailable")) unless @repost.publish_now!

        respond_with_post(I18n.t("reposts.flash.publishing_now"))
      end

      private

      def set_repost
        @repost = Repost.joins(:account).where(accounts: { user_id: current_user.id })
                        .where(post_id: params[:post_id]).find(params[:id])
      end

      def respond_with_post(message)
        render json: { post: serializer.post(@repost.post.reload, detail: true), message: message }
      end
    end
  end
end
