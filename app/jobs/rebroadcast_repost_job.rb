# frozen_string_literal: true

class RebroadcastRepostJob < ApplicationJob
  queue_as :default

  def perform(repost_id)
    repost = Repost.find(repost_id)
    return unless repost.can_rebroadcast?

    publisher = Nostr::EventPublisherService.new
    relays = (repost.account.write_relays || []) + (repost.account.user.custom_relays || [])
    results = publisher.publish(repost.signed_event, relays: relays)

    merged = (repost.publish_results || {}).merge(results)
    success_count = merged.values.count { |v| v == :ok || v == "ok" }

    if success_count > 0
      repost.update!(status: :published, published_at: repost.published_at || Time.current, publish_results: merged)
    else
      repost.update!(publish_results: merged)
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
