# frozen_string_literal: true

require "test_helper"

class UserTest < ActiveSupport::TestCase
  # H4: custom relays are dialled by the server, so unsafe URLs must never be
  # stored and the user has to be told why.
  def with_guard_enabled
    previous = Rails.application.config.x.allow_private_network_urls
    Rails.application.config.x.allow_private_network_urls = false
    yield
  ensure
    Rails.application.config.x.allow_private_network_urls = previous
  end

  def build_user
    User.create!(npub: "npub_test_#{SecureRandom.hex(4)}", pubkey_hex: SecureRandom.hex(32))
  end

  test "unsafe custom relays are rejected with a validation error" do
    with_guard_enabled do
      user = build_user
      user.custom_relays = "wss://relay.example.com\nws://127.0.0.1:4869\nhttp://example.com"

      refute user.valid?
      assert_match(/127\.0\.0\.1/, user.errors.full_messages.join(" "))
      assert_match(/example\.com/, user.errors.full_messages.join(" "))
      refute user.save
    end
  end

  test "safe custom relays are stored" do
    with_guard_enabled do
      user = build_user
      user.custom_relays = "wss://1.1.1.1\n\n  wss://8.8.8.8  "

      assert user.valid?, user.errors.full_messages.join(" ")
      assert user.save
      assert_equal [ "wss://1.1.1.1", "wss://8.8.8.8" ], user.reload.custom_relays
    end
  end
end
