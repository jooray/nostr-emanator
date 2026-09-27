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

    # Every step and error written onto the row is read later by the browser,
    # so produce it in the language of the user who asked for the update.
    update.user.with_locale { publish(update) }
  end

  private

  def publish(update)
    profile_update_id = update.id
    update.progress(I18n.t("profile_updates.steps.preparing"))

    progress = ->(_stage, message) { update.progress(message) }
    service = Nostr::ProfilePublisherService.new(update.account, progress: progress)

    service.publish(update.edits || {})
    update.succeed!

    # Refresh the cached columns the rest of the UI reads so the change is
    # visible immediately instead of waiting for the next profile refresh.
    FetchAccountProfileJob.perform_later(update.account_id)
  rescue Nostr::ProfilePublisherService::SigningError => e
    Rails.logger.warn("PublishProfileJob #{profile_update_id}: signing failed: #{e.message}")
    update&.fail!(I18n.t("profile_updates.errors.signing_failed"))
  rescue Nostr::ProfilePublisherService::PublishError => e
    update&.fail!(e.message)
  rescue StandardError => e
    Rails.logger.error("PublishProfileJob #{profile_update_id}: #{e.class}: #{e.message}")
    update&.fail!(I18n.t("profile_updates.errors.unexpected"))
    raise
  ensure
    # A worker shutdown interrupts the thread rather than raising StandardError,
    # so `rescue` alone would strand this row in `running` forever.
    update.fail!(I18n.t("profile_updates.errors.interrupted")) if update && !update.finished?
  end
end
