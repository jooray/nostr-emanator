# frozen_string_literal: true

require_relative "../../test_helper"

class UploadApiTest < ActionDispatch::IntegrationTest
  include ApiTestHelper
  include ActiveJob::TestHelper

  def setup
    @user = create_api_user
    @account = create_signed_account(@user)
  end

  def image_file
    file = Tempfile.new([ "photo", ".jpg" ])
    file.binmode
    file.write("\xFF\xD8\xFF\xE0fakejpeg".b)
    file.rewind
    Rack::Test::UploadedFile.new(file.path, "image/jpeg", true, original_filename: "photo.jpg")
  end

  def test_upload_is_staged_and_queued
    assert_enqueued_with(job: BlossomUploadJob) do
      post "/api/v1/accounts/#{@account.id}/uploads", params: { file: image_file }, headers: api_headers
    end
    assert_response :accepted
    id = json["id"]

    api_get "/api/v1/uploads/#{id}"
    assert_equal "pending", json["status"]
  ensure
    BlossomUpload.find_each(&:purge_file!)
  end

  def test_disallowed_type_is_refused
    file = Rack::Test::UploadedFile.new(StringIO.new("x"), "application/zip", original_filename: "a.zip")
    post "/api/v1/accounts/#{@account.id}/uploads", params: { file: file }, headers: api_headers

    assert_response :unprocessable_entity
  end
end
