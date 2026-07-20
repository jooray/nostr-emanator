# frozen_string_literal: true

class PublishNowRepostJob < ApplicationJob
  queue_as :default
  discard_on ActiveRecord::RecordNotFound

  def perform(repost_id)
    repost = Repost.find(repost_id)
    return unless repost.awaiting_signature?
    return unless repost.unsigned_event.present?
    return unless repost.account.has_signer?

    # Sign via NIP-46
    signer = Nostr::EventSignerService.new
    signed = signer.request_signature(repost.account, repost.unsigned_event)

    unless signed
      # C3: don't stomp a repost that a concurrent signer already advanced.
      if repost.fail_if_awaiting_signature!
        Rails.logger.warn("PublishNowRepostJob: Signing failed for repost #{repost_id}")
      else
        Rails.logger.info("PublishNowRepostJob: signing timed out for repost #{repost_id} but it is now #{repost.status}")
      end
      broadcast_progress(repost)
      return
    end

    unless repost.transition_status(from: :awaiting_signature, to: :publishing,
                                    attributes: { signed_event: signed, event_id: signed["id"] })
      Rails.logger.info("PublishNowRepostJob: repost #{repost_id} left awaiting_signature (#{repost.status}); discarding late signature")
      return
    end

    broadcast_progress(repost)

    return unless signed_event_verified?(repost) # M4

    # Publish immediately
    publisher = Nostr::EventPublisherService.new
    relays = (repost.account.write_relays || []) + (repost.account.user.custom_relays || [])
    results = publisher.publish(repost.signed_event, relays: relays)

    success_count = results.values.count { |v| v == :ok }

    if success_count > 0
      repost.update!(status: :published, published_at: Time.current, publish_results: results)
    else
      repost.update!(status: :failed, publish_results: results)
    end

    broadcast_progress(repost)
  end

  private

  def broadcast_progress(repost)
    post = repost.post
    post.reload
    Turbo::StreamsChannel.broadcast_replace_to(
      "post_publishing_#{post.id}",
      target: "reposts-list",
      partial: "posts/reposts_list",
      locals: { post: post }
    )
  rescue => e
    Rails.logger.error("Failed to broadcast publish-now repost progress: #{e.message}")
  end
end
