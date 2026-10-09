# frozen_string_literal: true

class RepostsController < ApplicationController
  def destroy
    @repost = find_repost

    unless @repost.can_cancel?
      redirect_to post_path(@repost.post), alert: t("reposts.flash.cannot_cancel")
      return
    end

    post = @repost.post
    @repost.destroy
    redirect_to post_path(post), notice: t("reposts.flash.cancelled")
  end

  def retry_sign
    @repost = find_repost

    unless @repost.can_retry_sign?
      redirect_to post_path(@repost.post), alert: t("reposts.flash.not_awaiting_signature")
      return
    end

    notice = @repost.retry_signing! == :sign_and_publish ? t("reposts.flash.retrying_sign_and_publish") : t("reposts.flash.retrying_sign")
    redirect_to post_path(@repost.post), notice: notice
  end

  def rebroadcast
    @repost = find_repost

    unless @repost.can_rebroadcast?
      redirect_to post_path(@repost.post), alert: t("reposts.flash.cannot_rebroadcast")
      return
    end

    RebroadcastRepostJob.perform_later(@repost.id)
    redirect_to post_path(@repost.post), notice: t("reposts.flash.rebroadcasting")
  end

  def publish_now
    @repost = find_repost

    unless @repost.can_publish_now?
      redirect_to post_path(@repost.post), alert: t("reposts.flash.not_ready")
      return
    end

    unless @repost.publish_now!
      redirect_to post_path(@repost.post), alert: t("reposts.flash.original_unavailable")
      return
    end

    redirect_to post_path(@repost.post), notice: t("reposts.flash.publishing_now")
  end

  private

  def find_repost
    Repost.joins(:account)
      .where(accounts: { user_id: current_user.id })
      .where(post_id: params[:post_id])
      .find(params[:id])
  end
end
