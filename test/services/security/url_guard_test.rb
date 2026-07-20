# frozen_string_literal: true

require "test_helper"

module Security
  class UrlGuardTest < ActiveSupport::TestCase
    # The guard is a no-op outside production unless explicitly switched on, so
    # every test here opts in.
    def with_guard_enabled
      previous = Rails.application.config.x.allow_private_network_urls
      Rails.application.config.x.allow_private_network_urls = false
      yield
    ensure
      Rails.application.config.x.allow_private_network_urls = previous
    end

    test "rejects loopback and link-local literals" do
      with_guard_enabled do
        %w[
          http://127.0.0.1/upload
          https://127.0.0.1/upload
          https://169.254.169.254/latest/meta-data/
          https://10.0.0.5/upload
          https://192.168.1.10/upload
          https://[::1]/upload
        ].each do |url|
          assert_raises(UrlGuard::UnsafeUrlError, "expected #{url} to be rejected") do
            UrlGuard.validate_http!(url)
          end
        end
      end
    end

    test "rejects plaintext and non-http schemes in production mode" do
      with_guard_enabled do
        assert_raises(UrlGuard::UnsafeUrlError) { UrlGuard.validate_http!("http://blossom.example.com") }
        assert_raises(UrlGuard::UnsafeUrlError) { UrlGuard.validate_relay!("ws://relay.example.com") }
        assert_raises(UrlGuard::UnsafeUrlError) { UrlGuard.validate_http!("file:///etc/passwd") }
        assert_raises(UrlGuard::UnsafeUrlError) { UrlGuard.validate_http!("gopher://example.com") }
      end
    end

    test "rejects blank, malformed and credential-bearing urls" do
      with_guard_enabled do
        assert_raises(UrlGuard::UnsafeUrlError) { UrlGuard.validate_http!("") }
        assert_raises(UrlGuard::UnsafeUrlError) { UrlGuard.validate_http!("https://") }
        assert_raises(UrlGuard::UnsafeUrlError) { UrlGuard.validate_http!("https://user:pass@example.com") }
      end
    end

    test "accepts public addresses" do
      with_guard_enabled do
        assert UrlGuard.safe?("https://1.1.1.1/upload", schemes: %w[https])
        assert UrlGuard.safe_relay?("wss://8.8.8.8")
      end
    end

    test "is permissive when private networks are allowed" do
      previous = Rails.application.config.x.allow_private_network_urls
      Rails.application.config.x.allow_private_network_urls = true
      assert UrlGuard.safe?("http://localhost:3001/upload", schemes: UrlGuard.http_schemes)
      assert UrlGuard.safe_relay?("ws://localhost:7777")
    ensure
      Rails.application.config.x.allow_private_network_urls = previous
    end
  end
end
