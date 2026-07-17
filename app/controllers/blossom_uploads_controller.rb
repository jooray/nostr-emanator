# frozen_string_literal: true

# Proxies a file upload from the post composer to the account's Blossom media
# server. The kind-24242 authorization is signed server-side via NIP-46, so this
# blocks while the remote signer (Amber) responds.
class BlossomUploadsController < ApplicationController
  before_action :authenticate_user!

  def create
    account = current_user.accounts.find(params[:account_id])
    file = params[:file]

    return render json: { error: "No file provided" }, status: :unprocessable_entity if file.blank?

    unless account.has_signer?
      return render json: { error: "This account has no paired signer" }, status: :unprocessable_entity
    end

    url = Nostr::BlossomUploaderService.new(account).upload(
      io: file.tempfile,
      filename: file.original_filename,
      content_type: file.content_type
    )

    render json: { url: url }
  rescue Nostr::BlossomUploaderService::UploadError => e
    render json: { error: e.message }, status: :unprocessable_entity
  end
end
