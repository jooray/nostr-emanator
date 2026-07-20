# frozen_string_literal: true

require_relative "../../jobs/job_test_helper"
require "digest"
require "tempfile"

# M5 (stream instead of buffering the file twice) and H10 (don't spend two Amber
# prompts on a server we already know has no /media endpoint).
class BlossomUploaderServiceTest < ActiveSupport::TestCase
  include JobTestHelper

  def test_hashes_by_streaming_and_sends_the_file_as_an_io_body
    account = build_account
    bytes = SecureRandom.random_bytes(200_000)
    file = tempfile(bytes)

    requests = []
    with_signer_double do |signed_tags|
      with_httpx(requests, url: "https://blossom.example/x.png") do
        service(account).upload(io: file, filename: "x.png", content_type: "image/png")
      end

      sha = signed_tags.last.find { |t| t.first == "x" }.last
      assert_equal Digest::SHA256.hexdigest(bytes), sha
    end

    assert_equal 1, requests.size
    body = requests.first[:body]
    refute body.is_a?(String), "body must be streamed, not a second in-memory copy"
    assert_equal bytes.bytesize.to_s, requests.first[:headers]["Content-Length"]
  end

  def test_cached_media_unsupported_costs_only_one_signature
    account = build_account
    account.mark_media_unsupported!
    refute account.blossom_media_supported?

    requests = []
    verbs = nil
    with_signer_double do |signed_tags|
      with_httpx(requests, url: "https://blossom.example/x.png") do
        service(account).upload(io: tempfile("abc"), filename: "x.png", content_type: "image/png")
      end
      verbs = signed_tags.map { |tags| tags.find { |t| t.first == "t" }.last }
    end

    assert_equal [ "upload" ], verbs, "should not prompt the signer for /media"
    assert_equal 1, requests.size
    assert_match %r{/upload\z}, requests.first[:url]
  end

  def test_progress_callback_announces_the_signer_prompt
    account = build_account
    account.mark_media_unsupported!
    messages = []

    with_signer_double do
      with_httpx([], url: "https://blossom.example/x.png") do
        Nostr::BlossomUploaderService
          .new(account, progress: ->(_stage, message) { messages << message })
          .upload(io: tempfile("abc"), filename: "x.png", content_type: "image/png")
      end
    end

    assert messages.any? { |m| m.match?(/Approve the upload in your signer app/) }, messages.inspect
  end

  def test_empty_file_is_rejected
    account = build_account

    with_signer_double do
      error = assert_raises(Nostr::BlossomUploaderService::UploadError) do
        service(account).upload(io: tempfile(""), filename: "x.png", content_type: "image/png")
      end
      assert_match(/Empty file/, error.message)
    end
  end

  private

  def service(account)
    Nostr::BlossomUploaderService.new(account)
  end

  def tempfile(bytes)
    file = Tempfile.new("blossom-test")
    file.binmode
    file.write(bytes)
    file.rewind
    file
  end

  # Yields an array that collects the tags of every event handed to the signer.
  def with_signer_double
    collected = []
    signer = Object.new
    signer.define_singleton_method(:build_unsigned_event) do |content:, kind:, pubkey:, created_at:, tags:|
      collected << tags
      { "kind" => kind, "content" => content, "tags" => tags, "pubkey" => pubkey }
    end
    signer.define_singleton_method(:request_signature) do |_account, unsigned|
      unsigned.merge("id" => "a" * 64, "sig" => "b" * 128)
    end

    stub_class_method(Nostr::EventSignerService, :new, ->(*_a, **_k) { signer }) do
      yield collected
    end
  end

  # Replaces HTTPX.with with a client double recording each PUT.
  def with_httpx(requests, url:, status: 200, &block)
    client = Object.new
    response = Struct.new(:status, :body, :headers).new(status, { "url" => url }.to_json, {})
    client.define_singleton_method(:put) do |target, body:|
      requests << { url: target, body: body, headers: @headers }
      response
    end
    client.define_singleton_method(:head) { |_target| Struct.new(:status).new(404) }
    client.define_singleton_method(:remember_headers) { |headers| @headers = headers }

    stub_class_method(HTTPX, :with, lambda { |opts = {}|
      client.remember_headers(opts[:headers] || {})
      client
    }, &block)
  end
end
