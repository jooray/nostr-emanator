# frozen_string_literal: true

class RebroadcastPostJob < ApplicationJob
  # M7: automatic retry cadence for posts that only reached some of their relays.
  AUTO_RETRY_WAIT = 10.minutes
  MAX_AUTO_ATTEMPTS = 3

  queue_as :default
  discard_on ActiveRecord::RecordNotFound

  # `attempt` is set only for automatic (partial-failure) rebroadcasts; manual
  # rebroadcasts pass nil and never chain.
  def perform(post_id, attempt = nil)
    post = Post.find(post_id)
    return unless post.can_rebroadcast?
    return unless signed_event_verified?(post) # M4

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
      next unless signed_event_verified?(repost) # M4

      repost_relays = (repost.account.write_relays || []) + (repost.account.user.custom_relays || [])
      repost_results = publisher.publish(repost.signed_event, relays: repost_relays)

      repost_merged = (repost.publish_results || {}).merge(repost_results)
      repost.update!(publish_results: repost_merged)
    end

    broadcast_progress(post)

    schedule_next_attempt(post, results, attempt)
  end

  private

  def schedule_next_attempt(post, results, attempt)
    return if attempt.nil? || attempt >= MAX_AUTO_ATTEMPTS
    return if results.blank?
    return if results.values.all? { |v| v == :ok || v == "ok" }

    self.class.set(wait: AUTO_RETRY_WAIT).perform_later(post.id, attempt + 1)
  end

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
  rescue => e
    Rails.logger.error("Failed to broadcast rebroadcast progress: #{e.message}")
  end
end
