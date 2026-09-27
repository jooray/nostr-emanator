# frozen_string_literal: true

# Tracks one kind-0 profile publication. Signing blocks on the user approving
# in their signer app, so the work happens in PublishProfileJob and the browser
# polls this row — the same shape BlossomUpload uses.
class ProfileUpdate < ApplicationRecord
  STATUSES = %w[pending running completed failed].freeze

  # A job killed by a deploy or process restart would otherwise leave the
  # browser polling a row that never moves. The signer itself is given ~120s,
  # so this has to sit comfortably beyond that.
  STUCK_AFTER = 6.minutes
  RETENTION = 6.hours

  belongs_to :user
  belongs_to :account

  validates :status, inclusion: { in: STATUSES }

  scope :stale, -> { where(created_at: ...RETENTION.ago) }

  def finished? = %w[completed failed].include?(status)

  def stuck?
    !finished? && created_at < STUCK_AFTER.ago
  end

  # Surfaced to the browser as the current status, so a stranded row reads as a
  # failure the user can act on rather than a spinner that never resolves.
  def display_status
    stuck? ? "failed" : status
  end

  def display_error
    return error if error.present?
    return I18n.t("profile_updates.abandoned") if stuck?

    nil
  end

  def progress(message)
    update_columns(status: "running", step: message, updated_at: Time.current)
  end

  def succeed!
    update!(status: "completed", step: nil, error: nil, finished_at: Time.current)
  end

  def fail!(message)
    update!(status: "failed", error: message.to_s.truncate(300), finished_at: Time.current)
  end

  def self.sweep_stale!
    stale.delete_all
  end
end
