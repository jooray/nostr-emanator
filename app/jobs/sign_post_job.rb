# frozen_string_literal: true

class SignPostJob < ApplicationJob
  queue_as :signing
  discard_on ActiveRecord::RecordNotFound

  def perform(post_id)
    post = Post.find(post_id)
    return unless post.awaiting_signature?
    return unless post.account.has_signer?

    signer = Nostr::EventSignerService.new

    # Sign the main post
    if post.unsigned_event.present? && post.signed_event.blank?
      signed = signer.request_signature(post.account, post.unsigned_event)
      if signed
        # Only the job still holding the awaiting_signature state may apply the
        # result — a concurrent signer may have finished first.
        if post.transition_status(from: :awaiting_signature, to: :scheduled,
                                  attributes: { signed_event: signed, event_id: signed["id"] })
          broadcast_signing_progress(post)
          # Auto-publish replies immediately (don't wait for EnqueueScheduledPostsJob)
          PublishPostJob.perform_later(post.id) if post.is_reply?
        else
          Rails.logger.info("SignPostJob: post #{post.id} already left awaiting_signature (#{post.status}); discarding late signature")
        end
      else
        # C3: never stomp a post that another signer already scheduled/published.
        if post.fail_if_awaiting_signature!
          broadcast_signing_progress(post, failed: true, error: "Signing timed out. Approve the request in your signer app and retry.")
        else
          Rails.logger.info("SignPostJob: signing timed out for post #{post.id} but it is now #{post.status}; leaving as is")
        end
        return
      end
    end

    sign_reposts(post, signer)
  end

  private

  # Each signature can block up to SIGN_TIMEOUT (120 s), so signing N reposts
  # serially could hold a worker for N × 2 minutes (M19). Sign in bounded
  # batches instead. The threads only do network IO — every DB write happens
  # back on this thread, so no extra connections are checked out.
  SIGN_CONCURRENCY = 3

  def sign_reposts(post, signer)
    pending = post.reposts.awaiting_signature.select do |repost|
      repost.unsigned_event.present? && repost.signed_event.blank?
    end
    return if pending.empty?

    # H15: a repost account without a paired signer can never be signed —
    # fail it loudly instead of stranding it in awaiting_signature forever.
    signable, unsignable = pending.partition { |repost| repost.account.has_signer? }
    unsignable.each do |repost|
      repost.fail_if_awaiting_signature!(publish_results: { "error" => "No paired signer for this account" })
    end
    broadcast_signing_progress(post) if unsignable.any?

    signable.each_slice(SIGN_CONCURRENCY) do |batch|
      results = batch.map do |repost|
        [ repost, Thread.new { signer.request_signature(repost.account, repost.unsigned_event) } ]
      end

      results.each do |repost, thread|
        signed_repost = begin
          thread.value
        rescue StandardError => e
          Rails.logger.warn("SignPostJob: repost #{repost.id} signing raised #{e.class}: #{e.message}")
          nil
        end

        if signed_repost
          repost.transition_status(
            from: :awaiting_signature, to: :scheduled,
            attributes: { signed_event: signed_repost, event_id: signed_repost["id"] }
          )
        else
          repost.fail_if_awaiting_signature!
        end
        broadcast_signing_progress(post)
      end
    end
  end

  def broadcast_signing_progress(post, failed: false, error: nil)
    post.reload
    Turbo::StreamsChannel.broadcast_replace_to(
      "post_signing_#{post.id}",
      target: "signing-progress",
      partial: "posts/signing_progress",
      locals: { post: post, failed: failed, error: error }
    )
    Turbo::StreamsChannel.broadcast_replace_to(
      "post_signing_#{post.id}",
      target: "reposts-list",
      partial: "posts/reposts_list",
      locals: { post: post }
    )
    # Update the status badge in the page header
    status_colors = {
      "published"          => "bg-green-100 text-green-800 dark:bg-green-900 dark:text-green-200",
      "scheduled"          => "bg-green-100 text-green-800 dark:bg-green-900 dark:text-green-200",
      "draft"              => "bg-blue-100 text-blue-800 dark:bg-blue-900 dark:text-blue-200",
      "awaiting_signature" => "bg-orange-100 text-orange-800 dark:bg-orange-900 dark:text-orange-200",
      "publishing"         => "bg-indigo-100 text-indigo-800 dark:bg-indigo-900 dark:text-indigo-200",
      "failed"             => "bg-red-100 text-red-800 dark:bg-red-900 dark:text-red-200"
    }
    badge_class = status_colors[post.status] || "bg-gray-100 text-gray-800 dark:bg-gray-700 dark:text-gray-200"
    badge_html = "<div id=\"post-status-badge\"><span class=\"inline-flex items-center px-2.5 py-0.5 rounded-full text-xs font-medium #{badge_class}\">#{ApplicationController.helpers.status_label(post.status)}</span></div>"
    Turbo::StreamsChannel.broadcast_replace_to(
      "post_signing_#{post.id}",
      target: "post-status-badge",
      html: badge_html
    )
  rescue => e
    Rails.logger.error("Failed to broadcast signing progress: #{e.message}")
  end
end
