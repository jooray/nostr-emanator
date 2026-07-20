# frozen_string_literal: true

class PublishRepostJob < ApplicationJob
  queue_as :default
  # Order matters: Rescuable matches handlers in reverse declaration order, so
  # discard_on must come LAST or the broad retry_on would swallow RecordNotFound
  # and retry a deleted record three times (L9).
  retry_on StandardError, wait: :polynomially_longer, attempts: 3
  discard_on ActiveRecord::RecordNotFound

  def perform(repost_id)
    repost = Repost.find(repost_id)
    return unless repost.scheduled? || repost.publishing?
    return unless repost.signed_event.present?

    # M4: re-verify the stored signature (see ApplicationJob).
    return repost.update!(status: :failed, publish_results: { "error" => "Stored signature failed verification. Re-sign this repost." }) unless signed_event_verified?(repost)

    # M8: same atomic claim as PublishPostJob.
    unless repost.claim_for_publishing!(allow_resume: executions > 1)
      Rails.logger.info("PublishRepostJob: repost #{repost_id} already claimed by another run (#{repost.status}); skipping")
      return
    end

    broadcast_repost_progress(repost)

    publisher = Nostr::EventPublisherService.new
    relays = (repost.account.write_relays || []) + (repost.account.user.custom_relays || [])
    results = publisher.publish(repost.signed_event, relays: relays)

    success_count = results.values.count { |v| v == :ok }

    if success_count > 0
      repost.update!(status: :published, published_at: Time.current, publish_results: results)
      # M7: some relays took it, some didn't — retry the failed ones later
      # rather than leaving the repost visible to only part of the network.
      if success_count < results.size
        RebroadcastRepostJob.set(wait: RebroadcastRepostJob::AUTO_RETRY_WAIT).perform_later(repost.id, 1)
      end
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
