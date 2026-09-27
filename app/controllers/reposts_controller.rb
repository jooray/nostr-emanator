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

    unless (@repost.awaiting_signature? || (@repost.failed? && @repost.signed_event.blank?)) && @repost.unsigned_event.present?
      redirect_to post_path(@repost.post), alert: t("reposts.flash.not_awaiting_signature")
      return
    end

    @repost.update!(status: :awaiting_signature, publish_results: nil) if @repost.failed?

    if @repost.post.published?
      PublishNowRepostJob.perform_later(@repost.id)
      redirect_to post_path(@repost.post), notice: t("reposts.flash.retrying_sign_and_publish")
    else
      SignRepostJob.perform_later(@repost.id)
      redirect_to post_path(@repost.post), notice: t("reposts.flash.retrying_sign")
    end
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

    unless @repost.scheduled? && @repost.signed_event.present?
      redirect_to post_path(@repost.post), alert: t("reposts.flash.not_ready")
      return
    end

    # Rebuild unsigned event with current timestamp
    post = @repost.post
    original_event = post.signed_event || post.unsigned_event

    unless original_event.present?
      redirect_to post_path(post), alert: t("reposts.flash.original_unavailable")
      return
    end

    signer = Nostr::EventSignerService.new
    unsigned = signer.build_unsigned_repost(
      original_event: original_event,
      pubkey: @repost.account.pubkey_hex,
      created_at: Time.current
    )

    @repost.update!(unsigned_event: unsigned, signed_event: nil, event_id: nil, status: :awaiting_signature)
    PublishNowRepostJob.perform_later(@repost.id)
    redirect_to post_path(post), notice: t("reposts.flash.publishing_now")
  end

  private

  def find_repost
    Repost.joins(:account)
      .where(accounts: { user_id: current_user.id })
      .where(post_id: params[:post_id])
      .find(params[:id])
  end
end
