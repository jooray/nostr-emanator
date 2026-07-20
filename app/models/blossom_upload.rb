# frozen_string_literal: true

# Tracks one media upload to a Blossom server (C6). The bytes are staged on
# local disk by BlossomUploadsController, the actual signing + HTTP PUT happens
# in BlossomUploadJob, and the browser polls this row for progress.
class BlossomUpload < ApplicationRecord
  # M5: hard limits enforced before the request body is ever read into memory.
  MAX_BYTES = 25.megabytes
  ALLOWED_CONTENT_TYPES = %w[application/pdf].freeze
  ALLOWED_CONTENT_TYPE_PREFIXES = %w[image/ video/ audio/].freeze

  # Rows (and their staged tempfiles) are disposable once the browser has read
  # the result; anything older than this is swept.
  RETENTION = 6.hours

  STATUSES = %w[pending signing uploading completed failed].freeze

  belongs_to :user
  belongs_to :account

  validates :status, inclusion: { in: STATUSES }
  # M5: the controller rejects oversized/disallowed files with a friendly error
  # before staging them; these validations are the defense-in-depth backstop so
  # no code path can queue an upload that breaks the limits.
  validates :byte_size, numericality: {
    only_integer: true, greater_than: 0, less_than_or_equal_to: MAX_BYTES
  }, allow_nil: false
  validate :content_type_allowed

  def content_type_allowed
    return if self.class.allowed_content_type?(content_type)

    errors.add(:content_type, "must be #{self.class.allowed_types_description}")
  end

  # A job that died (process restart) would otherwise leave the browser polling
  # a row that never moves.
  STUCK_AFTER = 6.minutes

  scope :stale, -> { where(created_at: ...RETENTION.ago) }

  # Cheap opportunistic cleanup, called when a new upload starts.
  def self.sweep_stale!
    stale.find_each do |upload|
      upload.purge_file!
      upload.destroy
    end
  end

  # Marks the row failed when its job clearly went away. Returns self.
  def fail_if_stuck!
    return self if finished?
    return self if updated_at > STUCK_AFTER.ago

    fail!("Upload timed out. Please try again.")
    self
  end

  STATUSES.each do |state|
    define_method("#{state}?") { status == state }
  end

  def self.allowed_content_type?(content_type)
    type = content_type.to_s.split(";").first.to_s.strip.downcase
    return false if type.blank?

    ALLOWED_CONTENT_TYPES.include?(type) ||
      ALLOWED_CONTENT_TYPE_PREFIXES.any? { |prefix| type.start_with?(prefix) }
  end

  def self.allowed_types_description
    "images, video, audio or PDF"
  end

  # Where staged uploads live. Kept out of ActiveStorage on purpose: the blob
  # never belongs to this app, it is a short-lived pass-through buffer.
  def self.staging_dir
    Rails.root.join("tmp", "blossom_uploads")
  end

  def finished?
    completed? || failed?
  end

  def progress(message)
    update_columns(step: message, updated_at: Time.current)
  end

  def start!(step:)
    update!(status: "signing", step: step)
  end

  def uploading!(step:)
    update!(status: "uploading", step: step)
  end

  def complete!(url)
    update!(status: "completed", url: url, step: nil, error: nil, finished_at: Time.current)
    purge_file!
  end

  def fail!(message)
    update!(status: "failed", error: message.to_s.truncate(500), step: nil, finished_at: Time.current)
    purge_file!
  end

  def purge_file!
    return if file_path.blank?

    File.delete(file_path) if File.exist?(file_path)
  rescue SystemCallError => e
    Rails.logger.warn("BlossomUpload #{id}: could not delete staged file: #{e.message}")
  ensure
    update_columns(file_path: nil, updated_at: Time.current) if persisted?
  end

  def as_status_json
    {
      id: id,
      status: status,
      step: step,
      url: url,
      error: error,
      filename: filename
    }
  end
end
