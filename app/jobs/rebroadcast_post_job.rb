# frozen_string_literal: true

class RebroadcastPostJob < ApplicationJob
  queue_as :default

  def perform(post_id)
    post = Post.find(post_id)
    return unless post.can_rebroadcast?

    publisher = Nostr::EventPublisherService.new
    relays = (post.account.write_relays || []) + (post.account.user.custom_relays || [])
    results = publisher.publish(post.signed_event, relays: relays)

    # Merge new results into existing publish_results
    merged = (post.publish_results || {}).merge(results)
    post.update!(publish_results: merged)

    broadcast_progress(post)

    # Also rebroadcast published reposts
    post.reposts.published.find_each do |repost|
      next unless repost.signed_event.present?

      repost_relays = (repost.account.write_relays || []) + (repost.account.user.custom_relays || [])
      repost_results = publisher.publish(repost.signed_event, relays: repost_relays)

      repost_merged = (repost.publish_results || {}).merge(repost_results)
      repost.update!(publish_results: repost_merged)
    end

    broadcast_progress(post)
  end

  private

  def broadcast_progress(post)
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
