# frozen_string_literal: true

require "fileutils"

# Accepts a file from the post composer, stages it on disk and hands the actual
# work (NIP-46 signing + PUT to the account's Blossom server) to
# BlossomUploadJob. The request returns 202 immediately with an upload id; the
# browser polls #show until the upload is completed/failed (C6).
class BlossomUploadsController < ApplicationController
  before_action :authenticate_user!

  # M5: an authenticated user could otherwise proxy unbounded data upstream.
  rate_limit to: 20, within: 1.minute,
             by: -> { current_user&.id || request.remote_ip },
             only: :create,
             with: :upload_rate_limited

  def create
    account = current_user.accounts.find(params[:account_id])
    file = params[:file]

    return render_error("No file provided") if file.blank?

    unless account.has_signer?
      return render_error("This account has no paired signer")
    end

    unless BlossomUpload.allowed_content_type?(file.content_type)
      return render_error("#{file.original_filename} is not an allowed file type " \
                          "(#{BlossomUpload.allowed_types_description})")
    end

    size = declared_size(file)
    if size.to_i > BlossomUpload::MAX_BYTES
      return render_error(
        "#{file.original_filename} is too large (#{number_to_human_size(size)}). " \
        "The limit is #{number_to_human_size(BlossomUpload::MAX_BYTES)}.",
        status: :payload_too_large
      )
    end
    return render_error("#{file.original_filename} is empty") if size.to_i.zero?

    BlossomUpload.sweep_stale!

    upload = BlossomUpload.create!(
      user: current_user,
      account: account,
      status: "pending",
      step: "Queued…",
      filename: file.original_filename,
      content_type: normalized_content_type(file.content_type),
      byte_size: size
    )

    stage_file!(upload, file)
    BlossomUploadJob.perform_later(upload.id)

    render json: status_payload(upload), status: :accepted
  rescue ActiveRecord::RecordInvalid => e
    render_error(e.record.errors.full_messages.to_sentence.presence || "Could not start the upload")
  end

  def show
    upload = BlossomUpload.where(user_id: current_user.id).find(params[:id])
    render json: status_payload(upload.fail_if_stuck!)
  end

  private

  # The whole file is already buffered by Rack before params are parsed, so the
  # cap is enforced against the declared content length first (cheap) and then
  # against the staged tempfile — both before anything reads the bytes.
  def declared_size(file)
    if file.respond_to?(:tempfile) && file.tempfile.respond_to?(:size)
      file.tempfile.size
    else
      request.content_length
    end
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

  def status_payload(upload)
    upload.as_status_json.merge(status_url: blossom_upload_path(upload))
  end

  def render_error(message, status: :unprocessable_entity)
    render json: { error: message, status: "failed" }, status: status
  end

  def upload_rate_limited
    render json: { error: "Too many uploads — please wait a minute and try again.", status: "failed" },
           status: :too_many_requests
  end

  def number_to_human_size(bytes)
    ActiveSupport::NumberHelper.number_to_human_size(bytes)
  end
end
