# frozen_string_literal: true

ENV["RAILS_ENV"] = "test"
require_relative "../config/environment"
require "minitest/autorun"
require "rails/test_help"

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
