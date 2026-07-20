# frozen_string_literal: true

require_relative "job_test_helper"
require "fileutils"

# C6/H10: the upload runs in a background job, so one file failing must not
# take the others down with it, and every outcome has to land on the row the
# browser is polling.
class BlossomUploadJobTest < ActiveSupport::TestCase
  include JobTestHelper

  def teardown
    FileUtils.rm_rf(BlossomUpload.staging_dir)
  end

  def test_successful_upload_completes_and_removes_the_staged_file
    upload = staged_upload(contents: "png-bytes")
    path = upload.file_path

    with_uploader(->(_io, _filename, _ct) { "https://blossom.example/abc.png" }) do
      BlossomUploadJob.perform_now(upload.id)
    end

    upload.reload
    assert_equal "completed", upload.status
    assert_equal "https://blossom.example/abc.png", upload.url
    assert_nil upload.file_path
    refute File.exist?(path), "staged file should be cleaned up"
  end

  def test_one_failing_file_does_not_affect_the_others
    ok_first = staged_upload(filename: "a.png")
    boom = staged_upload(filename: "b.png")
    ok_last = staged_upload(filename: "c.png")

    uploader = lambda do |_io, filename, _ct|
      raise Nostr::BlossomUploaderService::UploadError, "server said no" if filename == "b.png"

      "https://blossom.example/#{filename}"
    end

    with_uploader(uploader) do
      [ ok_first, boom, ok_last ].each { |u| BlossomUploadJob.perform_now(u.id) }
    end

    assert_equal "completed", ok_first.reload.status
    assert_equal "https://blossom.example/a.png", ok_first.url

    assert_equal "failed", boom.reload.status
    assert_equal "server said no", boom.error
    assert_nil boom.url

    # The upload queued *after* the failure still runs and succeeds.
    assert_equal "completed", ok_last.reload.status
    assert_equal "https://blossom.example/c.png", ok_last.url
  end

  def test_signing_failure_reports_an_actionable_error
    upload = staged_upload

    uploader = lambda do |_io, _filename, _ct|
      raise Nostr::BlossomUploaderService::SigningError, "Signing timed out or was rejected"
    end

    with_uploader(uploader) { BlossomUploadJob.perform_now(upload.id) }

    upload.reload
    assert_equal "failed", upload.status
    assert_match(/signer app/i, upload.error)
  end

  def test_missing_staged_file_fails_the_row_instead_of_hanging
    upload = staged_upload
    File.delete(upload.file_path)

    BlossomUploadJob.perform_now(upload.id)

    assert_equal "failed", upload.reload.status
    assert_match(/attach it again/, upload.error)
  end

  def test_stuck_row_is_failed_when_its_job_disappeared
    upload = staged_upload
    upload.update!(status: "signing")
    upload.update_columns(updated_at: (BlossomUpload::STUCK_AFTER + 1.minute).ago)

    upload.fail_if_stuck!

    assert_equal "failed", upload.reload.status
  end

  private

  def staged_upload(filename: "photo.png", contents: "bytes", content_type: "image/png")
    account = build_account
    upload = BlossomUpload.create!(
      user: account.user,
      account: account,
      filename: filename,
      content_type: content_type,
      byte_size: contents.bytesize
    )
    FileUtils.mkdir_p(BlossomUpload.staging_dir)
    path = BlossomUpload.staging_dir.join("#{upload.id}-test").to_s
    File.binwrite(path, contents)
    upload.update!(file_path: path)
    upload
  end

  # Stubs Nostr::BlossomUploaderService with a double whose #upload delegates to
  # `impl.call(io, filename, content_type)`.
  def with_uploader(impl, &block)
    service = Object.new
    service.define_singleton_method(:upload) do |io:, filename:, content_type:|
      impl.call(io, filename, content_type)
    end
    stub_class_method(Nostr::BlossomUploaderService, :new, ->(*_a, **_k) { service }, &block)
  end
end
