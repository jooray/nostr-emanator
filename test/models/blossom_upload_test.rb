# frozen_string_literal: true

require_relative "../jobs/job_test_helper"

# M5: size cap + content-type allowlist for Blossom media uploads.
class BlossomUploadTest < ActiveSupport::TestCase
  include JobTestHelper

  def test_allows_image_video_audio_and_pdf
    %w[image/png image/jpeg video/mp4 audio/mpeg application/pdf].each do |type|
      assert BlossomUpload.allowed_content_type?(type), "#{type} should be allowed"
    end
  end

  def test_allows_content_type_with_parameters_and_odd_casing
    assert BlossomUpload.allowed_content_type?("IMAGE/PNG")
    assert BlossomUpload.allowed_content_type?("image/jpeg; charset=binary")
  end

  def test_rejects_everything_else
    [
      "text/html", "application/javascript", "application/zip",
      "application/octet-stream", "application/x-sh", "", nil
    ].each do |type|
      refute BlossomUpload.allowed_content_type?(type), "#{type.inspect} should be rejected"
    end
  end

  def test_disallowed_content_type_cannot_be_persisted
    upload = build_upload(content_type: "text/html")

    refute upload.valid?
    assert_match(/images, video, audio or PDF/, upload.errors.full_messages.join)
  end

  def test_size_cap_is_enforced_at_25_megabytes
    assert_equal 25.megabytes, BlossomUpload::MAX_BYTES

    assert build_upload(byte_size: BlossomUpload::MAX_BYTES).valid?
    refute build_upload(byte_size: BlossomUpload::MAX_BYTES + 1).valid?
    refute build_upload(byte_size: 0).valid?
    refute build_upload(byte_size: nil).valid?
  end

  private

  def build_upload(**attrs)
    account = build_account
    BlossomUpload.new({
      user: account.user,
      account: account,
      filename: "photo.png",
      content_type: "image/png",
      byte_size: 1024
    }.merge(attrs))
  end
end
