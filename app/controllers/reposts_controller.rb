# frozen_string_literal: true

class RepostsController < ApplicationController
  def destroy
    @repost = find_repost

    unless @repost.can_cancel?
      redirect_to post_path(@repost.post), alert: "Cannot cancel this repost."
      return
    end

    post = @repost.post
    @repost.destroy
    redirect_to post_path(post), notice: "Repost cancelled."
  end

  def retry_sign
    @repost = find_repost

    unless (@repost.awaiting_signature? || (@repost.failed? && @repost.signed_event.blank?)) && @repost.unsigned_event.present?
      redirect_to post_path(@repost.post), alert: "Repost is not awaiting signature."
      return
    end

    @repost.update!(status: :awaiting_signature, publish_results: nil) if @repost.failed?

    if @repost.post.published?
      PublishNowRepostJob.perform_later(@repost.id)
      redirect_to post_path(@repost.post), notice: "Retrying repost signing and publish request..."
    else
      SignRepostJob.perform_later(@repost.id)
      redirect_to post_path(@repost.post), notice: "Retrying repost signing request..."
    end
  end

  def rebroadcast
    @repost = find_repost

    unless @repost.can_rebroadcast?
      redirect_to post_path(@repost.post), alert: "Cannot rebroadcast this repost."
      return
    end

    RebroadcastRepostJob.perform_later(@repost.id)
    redirect_to post_path(@repost.post), notice: "Rebroadcasting repost..."
  end

  def publish_now
    @repost = find_repost

    unless @repost.scheduled? && @repost.signed_event.present?
      redirect_to post_path(@repost.post), alert: "Repost is not ready to publish now."
      return
    end

    # Rebuild unsigned event with current timestamp
    post = @repost.post
    original_event = post.signed_event || post.unsigned_event

    unless original_event.present?
      redirect_to post_path(post), alert: "Original post event not available."
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
    redirect_to post_path(post), notice: "Re-signing and publishing repost now..."
  end

  private

  def find_repost
    Repost.joins(:account)
      .where(accounts: { user_id: current_user.id })
      .where(post_id: params[:post_id])
      .find(params[:id])
  end
end
