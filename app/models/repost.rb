# frozen_string_literal: true

class Repost < ApplicationRecord
  include StatusTransitions
  include RelayDelivery

  attribute :publish_results, :json
  attribute :signed_event, :json
  attribute :unsigned_event, :json

  belongs_to :post
  belongs_to :account

  # A repost is rendered by the same forme row as a post — it has its own
  # identity, hour, status and delivery, and borrows the note's text.
  delegate :content, to: :post

  enum :status, {
    pending_signature: 0,
    awaiting_signature: 1,
    scheduled: 2,
    publishing: 3,
    published: 4,
    failed: 5
  }

  STALE_PUBLISHING_AFTER = Post::STALE_PUBLISHING_AFTER
  STALE_SIGNING_AFTER = Post::STALE_SIGNING_AFTER

  validates :account_id, uniqueness: { scope: :post_id }

  scope :upcoming, -> { where(status: [:scheduled, :awaiting_signature]).where("scheduled_at > ?", Time.current).order(scheduled_at: :asc) }
  scope :stale_publishing, -> { where(status: :publishing).where(updated_at: ..STALE_PUBLISHING_AFTER.ago) }
  # L17: `pending_signature` reposts are touched by no job — sweep them too.
  scope :stale_signing, -> { where(status: [:awaiting_signature, :pending_signature]).where(updated_at: ..STALE_SIGNING_AFTER.ago) }

  # C4: allow cancelling a repost abandoned mid-publish.
  def can_cancel?
    !published?
  end

  def can_retry_sign?
    (awaiting_signature? || (failed? && signed_event.blank?)) && unsigned_event.present?
  end

  # Returns :sign_and_publish when the note is already out (so the repost goes
  # out the moment it is signed), :sign otherwise.
  def retry_signing!
    update!(status: :awaiting_signature, publish_results: nil) if failed?

    if post.published?
      PublishNowRepostJob.perform_later(id)
      :sign_and_publish
    else
      SignRepostJob.perform_later(id)
      :sign
    end
  end

  def can_publish_now?
    scheduled? && signed_event.present?
  end

  # Re-sign with the current time and publish at once. False when the original
  # note's event is gone, so there is nothing to repost.
  def publish_now!
    original_event = post.signed_event || post.unsigned_event
    return false if original_event.blank?

    unsigned = Nostr::EventSignerService.new.build_unsigned_repost(
      original_event: original_event,
      pubkey: account.pubkey_hex,
      created_at: Time.current
    )
    update!(unsigned_event: unsigned, signed_event: nil, event_id: nil, status: :awaiting_signature)
    PublishNowRepostJob.perform_later(id)
    true
  end

  def can_rebroadcast?
    (published? || failed? || publishing?) && signed_event.present?
  end
end
