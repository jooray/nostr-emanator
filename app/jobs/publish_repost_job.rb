# frozen_string_literal: true

class PublishRepostJob < ApplicationJob
  queue_as :default
  retry_on StandardError, wait: :polynomially_longer, attempts: 3

  def perform(repost_id)
    repost = Repost.find(repost_id)
    return unless repost.scheduled? || repost.publishing?
    return unless repost.signed_event.present?

    repost.update!(status: :publishing)
    broadcast_repost_progress(repost)

    publisher = Nostr::EventPublisherService.new
    relays = (repost.account.write_relays || []) + (repost.account.user.custom_relays || [])
    results = publisher.publish(repost.signed_event, relays: relays)

    success_count = results.values.count { |v| v == :ok }

    if success_count > 0
      repost.update!(status: :published, published_at: Time.current, publish_results: results)
    else
      repost.update!(status: :failed, publish_results: results)
    end

    broadcast_repost_progress(repost)
  end

  private

  def broadcast_repost_progress(repost)
    post = repost.post
    post.reload
    Turbo::StreamsChannel.broadcast_replace_to(
      "post_publishing_#{post.id}",
      target: "publish-progress",
      partial: "posts/publish_progress",
      locals: { post: post }
    )
    Turbo::StreamsChannel.broadcast_replace_to(
      "post_publishing_#{post.id}",
      target: "reposts-list",
      partial: "posts/reposts_list",
      locals: { post: post }
    )
  rescue => e
    Rails.logger.error("Failed to broadcast repost progress: #{e.message}")
  end
end
