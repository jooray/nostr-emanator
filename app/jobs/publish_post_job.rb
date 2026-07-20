# frozen_string_literal: true

class PublishPostJob < ApplicationJob
  queue_as :default
  # Order matters: Rescuable matches handlers in reverse declaration order, so
  # discard_on must come LAST or the broad retry_on would swallow RecordNotFound
  # and retry a deleted record three times (L9).
  retry_on StandardError, wait: :polynomially_longer, attempts: 3
  discard_on ActiveRecord::RecordNotFound

  # `resume: true` is passed by "Publish now", which already moved the post to
  # `publishing` in the request so the UI updates immediately.
  def perform(post_id, resume: false)
    post = Post.find(post_id)
    return unless post.scheduled? || post.publishing?
    return unless post.signed_event.present?

    # M4: re-verify the stored signature (see ApplicationJob).
    return post.update!(status: :failed, publish_results: { "error" => "Stored signature failed verification. Re-sign this post." }) unless signed_event_verified?(post)

    # M8: atomically claim the post. A duplicate job (e.g. re-enqueued by the
    # recurring job while this one is still running) loses the race and
    # returns; an ActiveJob retry of *this* job may resume from `publishing`.
    unless post.claim_for_publishing!(allow_resume: resume || executions > 1)
      Rails.logger.info("PublishPostJob: post #{post_id} already claimed by another run (#{post.status}); skipping")
      return
    end

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

    # M7: partial relay success — retry the stragglers automatically later.
    if success_count > 0 && success_count < results.size
      Rails.logger.info("PublishPostJob: post #{post.id} reached #{success_count}/#{results.size} relays; scheduling rebroadcast")
      RebroadcastPostJob.set(wait: RebroadcastPostJob::AUTO_RETRY_WAIT).perform_later(post.id, 1)
    end

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
    # C4: a broadcast hiccup must never fail the job — the event may already be
    # on the relays, and a retry would leave the post stuck in `publishing`.
  rescue => e
    Rails.logger.error("Failed to broadcast publish progress: #{e.message}")
  end
end
