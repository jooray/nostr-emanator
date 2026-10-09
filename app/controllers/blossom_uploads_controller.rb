# frozen_string_literal: true

# Accepts a file from the post composer; BlossomUploadIntake stages it and hands
# the actual work (NIP-46 signing + PUT to the account's Blossom server) to
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
    result = BlossomUploadIntake.new(current_user, account).accept(params[:file])
    return render_error(result.error, status: result.status) unless result.ok?

    render json: status_payload(result.upload), status: :accepted
  end

  def show
    upload = BlossomUpload.where(user_id: current_user.id).find(params[:id])
    render json: status_payload(upload.fail_if_stuck!)
  end

  private

  def status_payload(upload)
    upload.as_status_json.merge(status_url: blossom_upload_path(upload))
  end

  def render_error(message, status: :unprocessable_entity)
    render json: { error: message, status: "failed" }, status: status
  end

  def upload_rate_limited
    render json: { error: t("blossom_uploads.errors.rate_limited"), status: "failed" },
           status: :too_many_requests
  end
end
