# frozen_string_literal: true

require "test_helper"

class AccountTest < ActiveSupport::TestCase
  def build_account(attrs = {})
    pubkey = SecureRandom.hex(32)
    user = User.create!(pubkey_hex: pubkey, npub: Nostr::KeyConverter.hex_to_npub(pubkey))
    user.accounts.build({ pubkey_hex: SecureRandom.hex(32) }.merge(attrs))
  end

  def with_guard_enabled
    previous = Rails.application.config.x.allow_private_network_urls
    Rails.application.config.x.allow_private_network_urls = false
    yield
  ensure
    Rails.application.config.x.allow_private_network_urls = previous
  end

  test "rejects a blossom server pointing at an internal address" do
    with_guard_enabled do
      account = build_account
      account.blossom_server = "http://169.254.169.254/latest/meta-data/"

      assert_not account.valid?
      assert_match(/blossom/i, account.errors.full_messages.join)
    end
  end

  test "rejects a plaintext blossom server" do
    with_guard_enabled do
      account = build_account
      account.blossom_server = "http://blossom.example.com"

      assert_not account.valid?
    end
  end

  test "accepts a blank blossom server (uses the global default)" do
    account = build_account
    account.blossom_server = ""

    assert account.valid?, account.errors.full_messages.join(", ")
  end

  test "rejects an over-long personality" do
    account = build_account(personality: "x" * (Account::MAX_PERSONALITY_LENGTH + 1))

    assert_not account.valid?
    assert_includes account.errors.attribute_names, :personality
  end
end
