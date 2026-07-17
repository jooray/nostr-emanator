# frozen_string_literal: true

class SignPostJob < ApplicationJob
  queue_as :default

  def perform(post_id)
    post = Post.find(post_id)
    return unless post.awaiting_signature?
    return unless post.account.has_signer?

    signer = Nostr::EventSignerService.new

    # Sign the main post
    if post.unsigned_event.present? && post.signed_event.blank?
      signed = signer.request_signature(post.account, post.unsigned_event)
      if signed
        post.update!(signed_event: signed, event_id: signed["id"], status: :scheduled)
        broadcast_signing_progress(post)
        # Auto-publish replies immediately (don't wait for EnqueueScheduledPostsJob)
        PublishPostJob.perform_later(post.id) if post.is_reply?
      else
        post.update!(status: :failed)
        broadcast_signing_progress(post, failed: true, error: "Signing timed out. Approve the request in your signer app and retry.")
        return
      end
    end

    # Sign reposts
    post.reposts.awaiting_signature.each do |repost|
      next unless repost.unsigned_event.present? && repost.signed_event.blank?
      next unless repost.account.has_signer?

      signed_repost = signer.request_signature(repost.account, repost.unsigned_event)
      if signed_repost
        repost.update!(signed_event: signed_repost, event_id: signed_repost["id"], status: :scheduled)
      else
        repost.update!(status: :failed)
      end
      broadcast_signing_progress(post)
    end
  end

  private

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
    badge_html = "<div id=\"post-status-badge\"><span class=\"inline-flex items-center px-2.5 py-0.5 rounded-full text-xs font-medium #{badge_class}\">#{post.status.humanize}</span></div>"
    Turbo::StreamsChannel.broadcast_replace_to(
      "post_signing_#{post.id}",
      target: "post-status-badge",
      html: badge_html
    )
  end
end
