# frozen_string_literal: true

class Repost < ApplicationRecord
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

  validates :account_id, uniqueness: { scope: :post_id }

  scope :upcoming, -> { where(status: [:scheduled, :awaiting_signature]).where("scheduled_at > ?", Time.current).order(scheduled_at: :asc) }

  def can_cancel?
    !published? && !publishing?
  end

  def can_rebroadcast?
    (published? || failed? || publishing?) && signed_event.present?
  end
end
