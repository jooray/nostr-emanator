# frozen_string_literal: true

require "digest"

# API token for programmatic access (MCP server). Tokens are shown to the
# user once at creation and stored only as a SHA-256 digest.
class ApiToken < ApplicationRecord
  TOKEN_PREFIX = "emn_"

  belongs_to :user

  validates :name, presence: true
  validates :token_digest, presence: true, uniqueness: true

  attr_accessor :plain_token

  def self.generate(user, name:, expires_at: nil)
    plain = "#{TOKEN_PREFIX}#{SecureRandom.hex(32)}"
    token = user.api_tokens.new(
      name: name,
      token_digest: digest_for(plain),
      expires_at: expires_at
    )
    token.plain_token = plain
    token.save!
    token
  end

  def self.authenticate(plain)
    return nil if plain.blank?

    token = find_by(token_digest: digest_for(plain))
    return nil unless token
    return nil if token.expired?

    token.update_columns(last_used_at: Time.current)
    token.user
  end

  def self.digest_for(plain)
    Digest::SHA256.hexdigest(plain.to_s)
  end

  def expired?
    expires_at.present? && expires_at <= Time.current
  end

  def masked_preview
    "#{TOKEN_PREFIX}…#{token_digest.last(6)}"
  end
end
