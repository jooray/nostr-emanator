# frozen_string_literal: true

# C6: runs the Blossom upload (NIP-46 signing + HTTP PUT) outside the request
# cycle. It still costs a thread — Solid Queue runs in-process with Puma — but
# no longer pins a *Puma* thread for up to ~5 minutes, so the web app stays
# responsive while the user approves the request in Amber.
class BlossomUploadJob < ApplicationJob
  queue_as :default
  discard_on ActiveRecord::RecordNotFound

  def perform(upload_id)
    upload = BlossomUpload.find(upload_id)
    return if upload.finished?

    # Step and error strings are stored on the row and read later by the
    # composer, so they are written in the uploader's language.
    upload.user.with_locale { run(upload) }
  end

  private

  def run(upload)
    upload_id = upload.id

    path = upload.file_path
    unless path.present? && File.exist?(path)
      upload.fail!(I18n.t("blossom_uploads.errors.staged_file_gone"))
      return
    end

    upload.start!(step: I18n.t("blossom_uploads.steps.preparing"))

    progress = ->(_stage, message) { upload.progress(message) }
    service = Nostr::BlossomUploaderService.new(upload.account, progress: progress)

    File.open(path, "rb") do |io|
      url = service.upload(io: io, filename: upload.filename, content_type: upload.content_type)
      upload.complete!(url)
    end
  rescue Nostr::BlossomUploaderService::SigningError => e
    Rails.logger.warn("BlossomUploadJob #{upload_id}: signing failed: #{e.message}")
    upload&.fail!(I18n.t("blossom_uploads.errors.signing_failed"))
  rescue Nostr::BlossomUploaderService::UploadError => e
    upload&.fail!(e.message)
  rescue StandardError => e
    Rails.logger.error("BlossomUploadJob #{upload_id}: #{e.class}: #{e.message}")
    upload&.fail!(I18n.t("blossom_uploads.errors.unexpected"))
    raise
  end
end
