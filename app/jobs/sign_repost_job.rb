# frozen_string_literal: true

class SignRepostJob < ApplicationJob
  queue_as :default

  def perform(repost_id)
    repost = Repost.find(repost_id)
    return unless repost.awaiting_signature?
    return unless repost.unsigned_event.present? && repost.signed_event.blank?
    return unless repost.account.has_signer?

    signer = Nostr::EventSignerService.new
    signed = signer.request_signature(repost.account, repost.unsigned_event)

    if signed
      repost.update!(signed_event: signed, event_id: signed["id"], status: :scheduled)
      Rails.logger.info("SignRepostJob: Repost #{repost_id} signed successfully")
    else
      repost.update!(status: :failed)
      Rails.logger.warn("SignRepostJob: Repost #{repost_id} signing failed or timed out for account #{repost.account.npub}")
    end

    broadcast_progress(repost.post)
  end

  private

  def broadcast_progress(post)
    post.reload
    # Broadcast to both streams — signing stream is active when the post
    # is awaiting_signature, publishing stream when it's already scheduled
    %W[post_signing_#{post.id} post_publishing_#{post.id}].each do |stream|
      Turbo::StreamsChannel.broadcast_replace_to(
        stream,
        target: "reposts-list",
        partial: "posts/reposts_list",
        locals: { post: post }
      )
    end
  end
end
