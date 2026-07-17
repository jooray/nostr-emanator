# frozen_string_literal: true

require "json"
require "base64"
require "digest"

module Nostr
  # Uploads a file to a Blossom media server (https://github.com/hzrd149/blossom)
  # on behalf of an account, authorized by a kind-24242 event signed through the
  # account's NIP-46 remote signer (Amber).
  #
  # Media files (images/video) are sent to the BUD-05 /media endpoint when the
  # server supports it (strips EXIF/GPS, optimizes), falling back to the universal
  # BUD-02 /upload endpoint. Everything else goes straight to /upload.
  class BlossomUploaderService
    class UploadError < StandardError; end
    # Raised when the NIP-46 signing leg fails. Subclass of UploadError so the
    # controller still catches it, but it must NOT trigger a /media -> /upload
    # fallback (that would just prompt Amber a second time for nothing).
    class SigningError < UploadError; end

    AUTH_EXPIRY = 300 # seconds the kind-24242 auth event stays valid

    def initialize(account)
      @account = account
      @signer = Nostr::EventSignerService.new
    end

    # Returns the public Blossom URL for the uploaded blob.
    def upload(io:, filename:, content_type:)
      raise UploadError, "Account has no paired signer" unless @account.has_signer?

      bytes = io.read.b
      raise UploadError, "Empty file" if bytes.empty?

      sha = Digest::SHA256.hexdigest(bytes)
      server = @account.blossom_server
      content_type = content_type.presence || "application/octet-stream"

      # For media, try the BUD-05 /media endpoint first (strips EXIF/GPS). Many
      # servers (e.g. blossom.primal.net) don't implement it and reject the
      # `t=media` auth event ("invalid action"), so fall back to /upload on ANY
      # server-side failure — but not on a signing failure.
      if media?(content_type) && @account.blossom_media_supported?
        begin
          url = put_blob("#{server}/media", verb: "media", bytes: bytes, sha: sha, content_type: content_type)
          return ensure_extension(url, content_type)
        rescue SigningError
          raise
        rescue UploadError => e
          # Cache per-server so future uploads skip the wasted /media attempt.
          Rails.logger.info("Blossom: /media unavailable on #{server} (#{e.message}); falling back to /upload")
          @account.mark_media_unsupported!
        end
      end

      url = put_blob("#{server}/upload", verb: "upload", bytes: bytes, sha: sha, content_type: content_type)
      ensure_extension(url, content_type)
    end

    private

    # Returns the blob URL (String). Raises SigningError on signing failure and
    # UploadError on any non-2xx response or transport error.
    def put_blob(url, verb:, bytes:, sha:, content_type:)
      auth = build_auth_header(verb: verb, sha: sha)

      client = HTTPX.with(
        headers: { "Authorization" => auth, "Content-Type" => content_type },
        timeout: { connect_timeout: 30, read_timeout: 120, write_timeout: 120, request_timeout: 180 }
      )
      response = client.put(url, body: bytes)

      if response.is_a?(HTTPX::ErrorResponse)
        raise UploadError, "Could not reach Blossom server: #{response.error&.message}"
      end

      unless [200, 201].include?(response.status)
        raise UploadError, "Blossom upload failed (HTTP #{response.status}): #{failure_reason(response)}"
      end

      descriptor = JSON.parse(response.body.to_s)
      blob_url = descriptor["url"]
      raise UploadError, "Blossom response missing url" if blob_url.blank?

      blob_url
    rescue JSON::ParserError => e
      raise UploadError, "Invalid Blossom response: #{e.message}"
    end

    # Blossom servers report rejection reasons in the X-Reason header (BUD-01).
    def failure_reason(response)
      reason = response.headers["x-reason"] if response.respond_to?(:headers)
      reason.presence || response.body.to_s.truncate(200)
    end

    def build_auth_header(verb:, sha:)
      unsigned = @signer.build_unsigned_event(
        content: "Upload blob via Emanator",
        kind: 24242,
        pubkey: @account.pubkey_hex,
        created_at: Time.now,
        tags: [
          ["t", verb],
          ["x", sha],
          ["expiration", (Time.now + AUTH_EXPIRY).to_i.to_s]
        ]
      )

      signed = @signer.request_signature(@account, unsigned)
      raise SigningError, "Signing timed out or was rejected" unless signed

      "Nostr " + Base64.strict_encode64(JSON.generate(signed))
    end

    def media?(content_type)
      content_type.to_s.start_with?("image/", "video/")
    end

    # Nostr clients (and our media-preview) render by file extension, so make sure
    # the URL has one. Blossom URLs usually do; add one from the MIME type if not.
    def ensure_extension(url, content_type)
      return url if url.blank? || url[/\.[a-z0-9]{2,4}(\?|#|\z)/i]

      ext = MIME_EXTENSIONS[content_type]
      ext ? "#{url}.#{ext}" : url
    end

    MIME_EXTENSIONS = {
      "image/jpeg" => "jpg",
      "image/png" => "png",
      "image/gif" => "gif",
      "image/webp" => "webp",
      "video/mp4" => "mp4",
      "video/webm" => "webm",
      "video/quicktime" => "mov"
    }.freeze
  end
end
