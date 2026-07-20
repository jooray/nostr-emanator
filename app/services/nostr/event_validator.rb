# frozen_string_literal: true

require "digest"
require "json"
require "schnorr"

module Nostr
  module EventValidator
    HEX_32 = /\A[0-9a-f]{64}\z/i
    HEX_64 = /\A[0-9a-f]{128}\z/i

    def self.valid?(event, kind: nil, author: nil, recipient: nil)
      return false unless event.is_a?(Hash)
      return false unless event["pubkey"].is_a?(String) && event["pubkey"].match?(HEX_32)
      return false unless event["id"].is_a?(String) && event["id"].match?(HEX_32)
      return false unless event["sig"].is_a?(String) && event["sig"].match?(HEX_64)
      return false unless event["created_at"].is_a?(Integer) && event["kind"].is_a?(Integer)
      return false unless event["tags"].is_a?(Array) && event["content"].is_a?(String)
      return false if kind && event["kind"] != kind
      return false if author && event["pubkey"].downcase != author.downcase
      return false if recipient && !event["tags"].any? { |tag| tag.is_a?(Array) && tag[0] == "p" && tag[1]&.casecmp?(recipient) }

      id = event_id(event)
      return false unless ActiveSupport::SecurityUtils.secure_compare(id, event["id"].downcase)

      Schnorr.valid_sig?([id].pack("H*"), [event["pubkey"]].pack("H*"), [event["sig"]].pack("H*"))
    rescue StandardError
      false
    end

    def self.event_id(event)
      serialized = [0, event["pubkey"], event["created_at"], event["kind"], event["tags"], event["content"]]
      Digest::SHA256.hexdigest(JSON.generate(serialized))
    end
  end
end
