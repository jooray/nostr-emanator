# frozen_string_literal: true

class Repost < ApplicationRecord
  include StatusTransitions

  attribute :publish_results, :json
  attribute :signed_event, :json
  attribute :unsigned_event, :json

  belongs_to :post
  belongs_to :account

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

  def can_rebroadcast?
    (published? || failed? || publishing?) && signed_event.present?
  end
end
