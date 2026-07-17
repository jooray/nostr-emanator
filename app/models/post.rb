# frozen_string_literal: true

class Post < ApplicationRecord
  attribute :publish_results, :json
  attribute :signed_event, :json
  attribute :unsigned_event, :json
  attribute :version_history, :json, default: -> { [] }

  belongs_to :account
  has_many :reposts, dependent: :destroy

  enum :status, {
    draft: 0,
    awaiting_signature: 1,
    scheduled: 2,
    publishing: 3,
    published: 4,
    failed: 5
  }

  validates :content, presence: true
  validates :event_kind, inclusion: { in: [1] }

  scope :upcoming, -> { where(status: [:scheduled, :awaiting_signature]).where("scheduled_at > ?", Time.current).order(scheduled_at: :asc) }
  scope :past, -> { where(status: :published).order(published_at: :desc) }

  def can_edit?
    draft? || awaiting_signature?
  end

  def can_schedule?
    draft? || awaiting_signature?
  end

  def can_sign?
    awaiting_signature? && unsigned_event.present?
  end

  def can_publish?
    scheduled? && signed_event.present?
  end

  def can_cancel?
    awaiting_signature? || scheduled? || failed?
  end

  def can_reschedule?
    awaiting_signature? || scheduled? || failed?
  end

  def can_retry_publish?
    failed? && signed_event.present?
  end

  def can_rebroadcast?
    published? && signed_event.present?
  end

  def cancel!
    transaction do
      reposts.destroy_all
      update!(
        status: :draft,
        scheduled_at: nil,
        unsigned_event: nil,
        signed_event: nil,
        event_id: nil
      )
    end
  end

  def reschedule_reset!
    repost_account_ids = reposts.pluck(:account_id)
    transaction do
      reposts.destroy_all
      update!(
        status: :draft,
        scheduled_at: nil,
        unsigned_event: nil,
        signed_event: nil,
        event_id: nil
      )
    end
    repost_account_ids
  end
end
