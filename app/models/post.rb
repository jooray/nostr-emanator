# frozen_string_literal: true

class Post < ApplicationRecord
  include StatusTransitions

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

  # A record stuck in `publishing` longer than this is considered abandoned
  # (worker died, retries exhausted) and is swept by SweepStuckRecordsJob.
  STALE_PUBLISHING_AFTER = 15.minutes
  # Signing waits on the user's phone; anything older than this is a dead end.
  STALE_SIGNING_AFTER = 20.minutes

  validates :content, presence: true
  validates :event_kind, inclusion: { in: [1] }
  # H8: a post without a scheduled time can never be picked up by
  # EnqueueScheduledPostsJob — it would sit "Scheduled" forever, silently.
  validates :scheduled_at, presence: true, if: -> { scheduled? || awaiting_signature? }

  scope :upcoming, -> { where(status: [:scheduled, :awaiting_signature]).where("scheduled_at > ?", Time.current).order(scheduled_at: :asc) }
  scope :past, -> { where(status: :published).order(published_at: :desc) }
  scope :stale_publishing, -> { where(status: :publishing).where(updated_at: ..STALE_PUBLISHING_AFTER.ago) }
  scope :stale_signing, -> { where(status: :awaiting_signature).where(updated_at: ..STALE_SIGNING_AFTER.ago) }

  def can_edit?
    draft? || awaiting_signature?
  end

  def can_schedule?
    draft? || awaiting_signature?
  end

  def can_sign?
    awaiting_signature? && unsigned_event.present?
  end

  # C4: `publishing` is included so a post abandoned mid-publish can be
  # recovered from the UI instead of spinning forever.
  def can_cancel?
    awaiting_signature? || scheduled? || failed? || publishing?
  end

  def can_reschedule?
    awaiting_signature? || scheduled? || failed?
  end

  def can_retry_publish?
    (failed? || publishing?) && signed_event.present?
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
