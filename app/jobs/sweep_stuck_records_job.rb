# frozen_string_literal: true

# Reconciles posts/reposts that no other job will ever touch again:
#
#   * C4 — stuck in `publishing` (worker died, retries exhausted, a broadcast
#     blew up mid-flight). They are marked `failed` so the UI offers retry /
#     rebroadcast instead of spinning forever.
#   * H15/L17 — stuck in `awaiting_signature` (or `pending_signature` for
#     reposts) because the signer was never paired, the request was never
#     approved, or the process died between the controller update and the job.
class SweepStuckRecordsJob < ApplicationJob
  queue_as :default

  STUCK_PUBLISHING_ERROR = "Publishing did not complete — the worker stopped responding. Retry or rebroadcast."
  STUCK_SIGNING_ERROR = "Signing was never completed. Check your signer app is paired and retry."

  def perform
    swept = 0
    swept += sweep_publishing(Post)
    swept += sweep_publishing(Repost)
    swept += sweep_signing(Post)
    swept += sweep_signing(Repost)
    Rails.logger.info("SweepStuckRecordsJob: swept #{swept} stuck record(s)") if swept.positive?
    swept
  end

  private

  def sweep_publishing(klass)
    count = 0
    klass.stale_publishing.find_each do |record|
      stuck_since = record.updated_at
      next unless record.transition_status(
        from: :publishing, to: :failed,
        attributes: { publish_results: merged_error(record, STUCK_PUBLISHING_ERROR) }
      )

      count += 1
      Rails.logger.warn("SweepStuckRecordsJob: #{klass.name} #{record.id} stuck in publishing since #{stuck_since}; marked failed")
    end
    count
  end

  def sweep_signing(klass)
    count = 0
    klass.stale_signing.find_each do |record|
      stuck_since = record.updated_at
      from = klass == Repost ? [:awaiting_signature, :pending_signature] : [:awaiting_signature]
      next unless record.transition_status(
        from: from, to: :failed,
        attributes: { publish_results: merged_error(record, STUCK_SIGNING_ERROR) }
      )

      count += 1
      Rails.logger.warn("SweepStuckRecordsJob: #{klass.name} #{record.id} stuck awaiting signature since #{stuck_since}; marked failed")
    end
    count
  end

  def merged_error(record, message)
    (record.publish_results || {}).merge("error" => message)
  end
end
