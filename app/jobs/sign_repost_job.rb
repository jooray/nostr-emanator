# frozen_string_literal: true

class SignRepostJob < ApplicationJob
  queue_as :signing
  discard_on ActiveRecord::RecordNotFound

  def perform(repost_id)
    repost = Repost.find(repost_id)
    return unless repost.awaiting_signature?
    return unless repost.unsigned_event.present? && repost.signed_event.blank?
    return unless repost.account.has_signer?

    signer = Nostr::EventSignerService.new
    signed = signer.request_signature(repost.account, repost.unsigned_event)

    if signed
      if repost.transition_status(from: :awaiting_signature, to: :scheduled,
                                  attributes: { signed_event: signed, event_id: signed["id"] })
        Rails.logger.info("SignRepostJob: Repost #{repost_id} signed successfully")
      else
        Rails.logger.info("SignRepostJob: Repost #{repost_id} is now #{repost.status}; discarding late signature")
      end
    # C3: only fail a repost that is still waiting on this job's signature.
    elsif repost.fail_if_awaiting_signature!
      Rails.logger.warn("SignRepostJob: Repost #{repost_id} signing failed or timed out for account #{repost.account.npub}")
    else
      Rails.logger.info("SignRepostJob: signing timed out for repost #{repost_id} but it is now #{repost.status}; leaving as is")
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
  rescue => e
    Rails.logger.error("Failed to broadcast repost signing progress: #{e.message}")
  end
end
