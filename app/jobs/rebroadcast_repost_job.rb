# frozen_string_literal: true

class RebroadcastRepostJob < ApplicationJob
  queue_as :default
  discard_on ActiveRecord::RecordNotFound

  # M7: same auto-retry ladder as RebroadcastPostJob. `attempt` is nil for a
  # human-triggered rebroadcast (no chaining) and 1..MAX_AUTO_ATTEMPTS for the
  # automatic ones enqueued after a partial relay success.
  AUTO_RETRY_WAIT = RebroadcastPostJob::AUTO_RETRY_WAIT
  MAX_AUTO_ATTEMPTS = RebroadcastPostJob::MAX_AUTO_ATTEMPTS

  def perform(repost_id, attempt = nil)
    repost = Repost.find(repost_id)
    return unless repost.can_rebroadcast?
    return unless signed_event_verified?(repost) # M4

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
    schedule_auto_retry(repost, merged, attempt)
  end

  private

  def schedule_auto_retry(repost, results, attempt)
    return if attempt.nil? || attempt >= MAX_AUTO_ATTEMPTS

    total = results.size
    success_count = results.values.count { |v| v == :ok || v == "ok" }
    return unless total > 0 && success_count.between?(1, total - 1)

    self.class.set(wait: AUTO_RETRY_WAIT).perform_later(repost.id, attempt + 1)
  end

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
    Rails.logger.error("Failed to broadcast repost rebroadcast progress: #{e.message}")
  end
end
