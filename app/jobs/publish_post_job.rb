# frozen_string_literal: true

class PublishPostJob < ApplicationJob
  queue_as :default
  retry_on StandardError, wait: :polynomially_longer, attempts: 3

  def perform(post_id)
    post = Post.find(post_id)
    return unless post.scheduled? || post.publishing?
    return unless post.signed_event.present?

    post.update!(status: :publishing)
    broadcast_publish_progress(post)

    publisher = Nostr::EventPublisherService.new
    relays = (post.account.write_relays || []) + (post.account.user.custom_relays || [])
    results = publisher.publish(post.signed_event, relays: relays)

    success_count = results.values.count { |v| v == :ok }

    if success_count > 0
      post.update!(status: :published, published_at: Time.current, publish_results: results)
    else
      post.update!(status: :failed, publish_results: results)
    end

    broadcast_publish_progress(post)

    # Enqueue reposts if post succeeded
    if post.published?
      post.reposts.scheduled.where("scheduled_at <= ?", Time.current).find_each do |repost|
        PublishRepostJob.perform_later(repost.id)
      end
    end
  end

  private

  def broadcast_publish_progress(post)
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
  end
end
