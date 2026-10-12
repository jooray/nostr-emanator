# frozen_string_literal: true

require "fileutils"

# Accepts one uploaded file for an account: validates it, stages the bytes on
# disk, creates the BlossomUpload row and enqueues BlossomUploadJob. The web
# composer and the native app both come through here, so the limits (99 MB,
# the content-type allowlist, a paired signer) cannot differ between them.
class BlossomUploadIntake
  Result = Struct.new(:upload, :error, :status, keyword_init: true) do
    def ok? = upload.present?
  end

  def initialize(user, account)
    @user = user
    @account = account
  end

  # `file` is an ActionDispatch::Http::UploadedFile.
  def accept(file)
    return failure(I18n.t("blossom_uploads.errors.no_file")) if file.blank?
    return failure(I18n.t("blossom_uploads.errors.no_signer")) unless @account.has_signer?

    unless BlossomUpload.allowed_content_type?(file.content_type)
      return failure(I18n.t("blossom_uploads.errors.type_not_allowed",
                            filename: file.original_filename,
                            types: BlossomUpload.allowed_types_description))
    end

    size = declared_size(file)
    if size.to_i > BlossomUpload::MAX_BYTES
      return failure(
        I18n.t("blossom_uploads.errors.too_large",
               filename: file.original_filename,
               size: human_size(size),
               limit: human_size(BlossomUpload::MAX_BYTES)),
        status: :payload_too_large
      )
    end
    return failure(I18n.t("blossom_uploads.errors.empty", filename: file.original_filename)) if size.to_i.zero?

    BlossomUpload.sweep_stale!

    upload = BlossomUpload.create!(
      user: @user,
      account: @account,
      status: "pending",
      step: I18n.t("blossom_uploads.steps.queued"),
      filename: file.original_filename,
      content_type: normalized_content_type(file.content_type),
      byte_size: size
    )

    stage_file!(upload, file)
    BlossomUploadJob.perform_later(upload.id)
    Result.new(upload: upload)
  rescue ActiveRecord::RecordInvalid => e
    failure(e.record.errors.full_messages.to_sentence.presence || I18n.t("blossom_uploads.errors.could_not_start"))
  end

  private

  # The whole file is already buffered by Rack before params are parsed, so the
  # cap is enforced against the staged tempfile — before anything reads it.
  def declared_size(file)
    file.tempfile.size if file.respond_to?(:tempfile) && file.tempfile.respond_to?(:size)
  end

  def normalized_content_type(content_type)
    content_type.to_s.split(";").first.to_s.strip.downcase.presence || "application/octet-stream"
  end

  # Rack unlinks the multipart tempfile when the request ends, so copy the bytes
  # (streamed, never held in memory) somewhere the job can still find them.
  def stage_file!(upload, file)
    dir = BlossomUpload.staging_dir
    FileUtils.mkdir_p(dir)
    path = dir.join("#{upload.id}-#{SecureRandom.hex(8)}").to_s

    File.open(path, "wb") { |dest| IO.copy_stream(file.tempfile, dest) }
    upload.update!(file_path: path)
  end

  def human_size(bytes) = ActiveSupport::NumberHelper.number_to_human_size(bytes)

  def failure(message, status: :unprocessable_entity) = Result.new(error: message, status: status)
end
