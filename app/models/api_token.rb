# frozen_string_literal: true

require "digest"

# API token for programmatic access (MCP server). Tokens are shown to the
# user once at creation and stored only as a SHA-256 digest.
class ApiToken < ApplicationRecord
  TOKEN_PREFIX = "emn_"

  # M6: leaked tokens shouldn't grant access forever. Callers (the token
  # creation form) can still pass `expires_at: nil` explicitly for "never".
  DEFAULT_EXPIRY = 90.days

  # I4: MCP calls are frequent; only bump `last_used_at` at most this often
  # to avoid a DB write on every authenticated request.
  LAST_USED_THROTTLE = 5.minutes

  belongs_to :user

  validates :name, presence: true
  validates :token_digest, presence: true, uniqueness: true

  attr_accessor :plain_token

  def self.generate(user, name:, expires_at: DEFAULT_EXPIRY.from_now)
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

    token.touch_last_used!
    token.user
  end

  def self.digest_for(plain)
    Digest::SHA256.hexdigest(plain.to_s)
  end

  def expired?
    expires_at.present? && expires_at <= Time.current
  end

  # I4: write-amplification guard — skip the UPDATE if we touched this
  # recently (e.g. rapid MCP tool calls in the same session).
  def touch_last_used!
    return if last_used_at.present? && last_used_at > LAST_USED_THROTTLE.ago

    update_columns(last_used_at: Time.current)
  end

  def masked_preview
    "#{TOKEN_PREFIX}…#{token_digest.last(6)}"
  end
end
