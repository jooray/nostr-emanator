# frozen_string_literal: true

module Nostr
  # NIP-42 relay authentication (kind 22242).
  #
  # Needed because the DM inbox relays that actually honour NIP-17's
  # metadata-protection SHOULD — auth.nostr1.com and inbox.nostr.wine, both
  # verified live — refuse to serve kind 1059 to an unauthenticated client. Without
  # this, an account whose kind 10050 points at either of them has a silently
  # empty inbox.
  #
  # Note what the relay actually sends: `["AUTH", <challenge>]` usually arrives
  # immediately on connect, and strfry re-sends the SAME challenge alongside the
  # rejection — so keep an overwritable slot rather than assuming one per
  # connection. A REQ that needs auth is answered with
  # `["CLOSED", <sub>, "auth-required: …"]`, which DESTROYS the subscription: the
  # client must re-send the REQ after authenticating.
  module RelayAuth
    AUTH_KIND = 22_242
    # Relays allow roughly ten minutes of skew; never future-date, because
    # inbox.nostr.wine caps forward skew at 300 seconds.
    CACHE_TTL_OK = 1.hour
    # A signer that refuses (Amber auto-rejects 22242 for relays missing from a
    # non-empty whitelist) must not be re-prompted every minute.
    CACHE_TTL_REJECTED = 6.hours
    REQUIRES_AUTH_TTL = 24.hours

    class << self
      def build_unsigned(relay_url:, challenge:, pubkey:)
        {
          "pubkey" => pubkey,
          "created_at" => Time.now.to_i,
          "kind" => AUTH_KIND,
          "tags" => [ [ "relay", canonical_url(relay_url) ], [ "challenge", challenge.to_s ] ],
          "content" => ""
        }
      end

      # `restricted:` means we authenticated with the wrong key — a hard failure,
      # never worth retrying. `auth-required:` means try again after AUTH.
      def classify(reason)
        text = reason.to_s
        return :auth_required if text.start_with?("auth-required:")
        return :restricted if text.start_with?("restricted:")

        :other
      end

      # Some relays string-compare this tag, so send what we actually connected to.
      def canonical_url(relay_url)
        uri = URI.parse(relay_url.to_s)
        port = uri.port && uri.port != uri.default_port ? ":#{uri.port}" : ""
        path = uri.path.to_s.chomp("/")
        "#{uri.scheme}://#{uri.host}#{port}#{path}"
      rescue URI::InvalidURIError
        relay_url.to_s
      end

      def host(relay_url)
        URI.parse(relay_url.to_s).host.to_s
      rescue URI::InvalidURIError
        relay_url.to_s
      end

      # Seeded from config so we can authenticate on the AUTH frame rather than
      # paying a rejected-subscription round-trip to discover the requirement.
      def requires_auth?(relay_url)
        cached = Rails.cache.read(requires_auth_key(relay_url))
        return cached unless cached.nil?

        configured = Array(Rails.application.config_for(:emanator).dig(:nostr, :auth_required_relays))
        configured.any? { |url| host(url) == host(relay_url) }
      end

      def remember_requires_auth!(relay_url, value = true)
        Rails.cache.write(requires_auth_key(relay_url), value, expires_in: REQUIRES_AUTH_TTL)
      end

      def rejected?(relay_url, pubkey)
        Rails.cache.read(result_key(relay_url, pubkey)) == :rejected
      end

      def remember_result!(relay_url, pubkey, result)
        Rails.cache.write(
          result_key(relay_url, pubkey), result,
          expires_in: result == :ok ? CACHE_TTL_OK : CACHE_TTL_REJECTED
        )
      end

      private

      def requires_auth_key(relay_url) = "relay_requires_auth_#{host(relay_url)}"
      def result_key(relay_url, pubkey) = "relay_auth_#{host(relay_url)}_#{pubkey}"
    end
  end
end
