# frozen_string_literal: true

class PublishNowRepostJob < ApplicationJob
  queue_as :default

  def perform(repost_id)
    repost = Repost.find(repost_id)
    return unless repost.awaiting_signature?
    return unless repost.unsigned_event.present?
    return unless repost.account.has_signer?

    # Sign via NIP-46
    signer = Nostr::EventSignerService.new
    signed = signer.request_signature(repost.account, repost.unsigned_event)

    unless signed
      repost.update!(status: :failed)
      Rails.logger.warn("PublishNowRepostJob: Signing failed for repost #{repost_id}")
      broadcast_progress(repost)
      return
    end

    repost.update!(signed_event: signed, event_id: signed["id"], status: :publishing)
    broadcast_progress(repost)

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
  end
end
