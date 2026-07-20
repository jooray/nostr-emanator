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
  #
  # This runs in BlossomUploadJob, never in a web request: `request_signature`
  # blocks until the user approves in Amber (up to 120 s), and the PUT itself has
  # a 180 s request timeout (C6).
  class BlossomUploaderService
    class UploadError < StandardError; end
    # Raised when the NIP-46 signing leg fails. Subclass of UploadError so the
    # caller still catches it, but it must NOT trigger a /media -> /upload
    # fallback (that would just prompt Amber a second time for nothing).
    class SigningError < UploadError; end

    AUTH_EXPIRY = 300 # seconds the kind-24242 auth event stays valid
    HASH_CHUNK = 64 * 1024

    def initialize(account, progress: nil)
      @account = account
      @signer = Nostr::EventSignerService.new
      @progress = progress # ->(stage, message) — surfaces step-level status (H10)
    end

    # `io` must be a rewindable IO (a File/Tempfile): the bytes are hashed with a
    # streaming read and handed to HTTPX as an IO body, so we never hold the file
    # in memory (M5).
    # Returns the public Blossom URL for the uploaded blob.
    def upload(io:, filename:, content_type:)
      raise UploadError, "Account has no paired signer" unless @account.has_signer?

      size, sha = digest_stream(io)
      raise UploadError, "Empty file" if size.zero?

      server = safe_server
      content_type = content_type.presence || "application/octet-stream"

      # For media, try the BUD-05 /media endpoint first (strips EXIF/GPS). Many
      # servers (e.g. blossom.primal.net) don't implement it and reject the
      # `t=media` auth event ("invalid action"), so fall back to /upload on ANY
      # server-side failure — but not on a signing failure. The per-server
      # "unsupported" cache (and the unauthenticated probe below) keep this from
      # costing a wasted Amber prompt more than once per server (H10).
      if try_media?(content_type, server)
        begin
          url = put_blob("#{server}/media", verb: "media", io: io, size: size, sha: sha,
                                            content_type: content_type, attempt: 1, attempts: 2)
          return ensure_extension(url, content_type)
        rescue SigningError
          raise
        rescue UploadError => e
          # Cache per-server so future uploads skip the wasted /media attempt.
          Rails.logger.info("Blossom: /media unavailable on #{server} (#{e.message}); falling back to /upload")
          @account.mark_media_unsupported!
          report(:fallback, "Media endpoint unavailable — retrying with the standard endpoint")
        end
      end

      url = put_blob("#{server}/upload", verb: "upload", io: io, size: size, sha: sha,
                                         content_type: content_type)
      ensure_extension(url, content_type)
    end

    private

    def report(stage, message)
      @progress&.call(stage, message)
    end

    # Streaming SHA-256 — returns [byte_size, hex_digest] without materialising
    # the file in memory (M5).
    def digest_stream(io)
      io.rewind if io.respond_to?(:rewind)
      digest = Digest::SHA256.new
      size = 0
      while (chunk = io.read(HASH_CHUNK))
        size += chunk.bytesize
        digest.update(chunk)
      end
      io.rewind if io.respond_to?(:rewind)
      [ size, digest.hexdigest ]
    end

    def media?(content_type)
      content_type.to_s.start_with?("image/", "video/")
    end

    # Should we spend a signature on the BUD-05 /media endpoint?
    def try_media?(content_type, server)
      return false unless media?(content_type)
      return false unless @account.blossom_media_supported?

      # H10: probe without a signature first. A server that doesn't route /media
      # at all answers 404/405/501; cache that and skip straight to /upload so the
      # user is never prompted twice. Anything else (incl. 401 "auth required")
      # is inconclusive, so we still try.
      if media_endpoint_missing?(server)
        Rails.logger.info("Blossom: #{server} has no /media endpoint (probe); using /upload")
        @account.mark_media_unsupported!
        return false
      end

      true
    end

    def media_endpoint_missing?(server)
      response = HTTPX.with(timeout: { connect_timeout: 5, request_timeout: 8 }).head("#{server}/media")
      return false if response.is_a?(HTTPX::ErrorResponse)

      [ 404, 405, 501 ].include?(response.status)
    rescue StandardError => e
      Rails.logger.debug("Blossom: /media probe failed on #{server}: #{e.message}")
      false
    end

    # Returns the blob URL (String). Raises SigningError on signing failure and
    # UploadError on any non-2xx response or transport error.
    def put_blob(url, verb:, io:, size:, sha:, content_type:, attempt: nil, attempts: nil)
      auth = build_auth_header(verb: verb, sha: sha, attempt: attempt, attempts: attempts)

      report(:uploading, "Uploading to the media server…")
      io.rewind if io.respond_to?(:rewind)

      client = HTTPX.with(
        headers: {
          "Authorization" => auth,
          "Content-Type" => content_type,
          "Content-Length" => size.to_s
        },
        timeout: { connect_timeout: 30, read_timeout: 120, write_timeout: 120, request_timeout: 180 }
      )
      response = client.put(url, body: io)

      if response.is_a?(HTTPX::ErrorResponse)
        raise UploadError, "Could not reach Blossom server: #{response.error&.message}"
      end

      unless [ 200, 201 ].include?(response.status)
        raise UploadError, "Blossom upload failed (HTTP #{response.status}): #{failure_reason(response)}"
      end

      descriptor = JSON.parse(response.body.to_s)
      blob_url = descriptor["url"]
      raise UploadError, "Blossom response missing url" if blob_url.blank?

      blob_url
    rescue JSON::ParserError => e
      raise UploadError, "Invalid Blossom response: #{e.message}"
    end

    # H1: the media server is user-controlled, so re-check it here — the account
    # validation can be bypassed by a stale value or a changed global default,
    # and this is the last point before we open a connection.
    def safe_server
      server = @account.blossom_server
      Security::UrlGuard.validate!(server, schemes: Security::UrlGuard.http_schemes)
      server
    rescue Security::UrlGuard::UnsafeUrlError => e
      raise UploadError, "Media server rejected: #{e.message}"
    end

    # Blossom servers report rejection reasons in the X-Reason header (BUD-01).
    # H1: only the (short, server-authored) X-Reason header is shown; response
    # bodies are logged but never surfaced, so a misdirected upload cannot be
    # used to read back an internal endpoint's output.
    def failure_reason(response)
      reason = response.headers["x-reason"] if response.respond_to?(:headers)
      return reason.truncate(120) if reason.present?

      Rails.logger.info("Blossom: rejection body #{response.body.to_s.truncate(200).inspect}")
      "the media server rejected the upload"
    end

    def build_auth_header(verb:, sha:, attempt: nil, attempts: nil)
      unsigned = @signer.build_unsigned_event(
        content: "Upload blob via Emanator",
        kind: 24242,
        pubkey: @account.pubkey_hex,
        created_at: Time.now,
        tags: [
          [ "t", verb ],
          [ "x", sha ],
          [ "expiration", (Time.now + AUTH_EXPIRY).to_i.to_s ]
        ]
      )

      counter = attempt && attempts ? " (#{attempt} of #{attempts})" : ""
      report(:signing, "Approve the upload in your signer app#{counter}…")

      signed = @signer.request_signature(@account, unsigned)
      raise SigningError, "Signing timed out or was rejected" unless signed

      "Nostr " + Base64.strict_encode64(JSON.generate(signed))
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
