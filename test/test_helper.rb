# frozen_string_literal: true

ENV["RAILS_ENV"] = "test"
require_relative "../config/environment"
require "minitest/autorun"
require "rails/test_help"

# `TEST_LOCALE=sk bin/rails test test/i18n` renders everything in another
# language. Assertions on English text then fail by design; what matters is
# that nothing raises (a missing key or plural form) or answers 500.
I18n.default_locale = ENV["TEST_LOCALE"].to_sym if ENV["TEST_LOCALE"].present?

Dir[File.expand_path("support/**/*.rb", __dir__)].each { |file| require file }

module NostrTestHelper
  def keypair
    pair = ::Nostr::Keygen.new.generate_key_pair
    [pair.public_key.to_s, pair.private_key.to_s]
  end

  def signed_event(privkey:, pubkey:, kind:, content:, tags: [], created_at: Time.now.to_i)
    event = {
      "pubkey" => pubkey,
      "created_at" => created_at,
      "kind" => kind,
      "tags" => tags,
      "content" => content
    }
    event["id"] = Nostr::EventValidator.event_id(event)
    event["sig"] = Schnorr.sign([event["id"]].pack("H*"), [privkey].pack("H*")).encode.unpack1("H*")
    event
  end
end
