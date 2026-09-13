# frozen_string_literal: true

# Publishes a kind-0 profile outside the request cycle. Signing blocks on the
# user approving in their signer app (up to ~120s), which must never hold a Puma
# thread — the browser polls the ProfileUpdate row instead.
class PublishProfileJob < ApplicationJob
  queue_as :default
  discard_on ActiveRecord::RecordNotFound

  def perform(profile_update_id)
    update = ProfileUpdate.find(profile_update_id)
    return if update.finished?

    update.progress("Preparing…")

    progress = ->(_stage, message) { update.progress(message) }
    service = Nostr::ProfilePublisherService.new(update.account, progress: progress)

    service.publish(update.edits || {})
    update.succeed!

    # Refresh the cached columns the rest of the UI reads so the change is
    # visible immediately instead of waiting for the next profile refresh.
    FetchAccountProfileJob.perform_later(update.account_id)
  rescue Nostr::ProfilePublisherService::SigningError => e
    Rails.logger.warn("PublishProfileJob #{profile_update_id}: signing failed: #{e.message}")
    update&.fail!("Signing timed out or was rejected. Approve the request in your signer app and try again.")
  rescue Nostr::ProfilePublisherService::PublishError => e
    update&.fail!(e.message)
  rescue StandardError => e
    Rails.logger.error("PublishProfileJob #{profile_update_id}: #{e.class}: #{e.message}")
    update&.fail!("Publishing failed unexpectedly. Please try again.")
    raise
  ensure
    # A worker shutdown interrupts the thread rather than raising StandardError,
    # so `rescue` alone would strand this row in `running` forever.
    update.fail!("Interrupted before it finished. Please try again.") if update && !update.finished?
  end
end
