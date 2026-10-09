# frozen_string_literal: true

require "digest"

# Bearer credential, stored only as a SHA-256 digest; the plaintext is shown once.
#
# Two kinds share the table and never each other's endpoints:
#
#   mcp     made by hand in Settings for an AI agent. Reaches /mcp only — posts
#           and scheduling, never private messages.
#   device  minted by a native-app login. Reaches /api/v1 only — the whole app,
#           messages included, which is exactly why an agent's token must not.
class ApiToken < ApplicationRecord
  TOKEN_PREFIX = "emn_"
  DEVICE_TOKEN_PREFIX = "emd_"
  KINDS = %w[mcp device].freeze

  # M6: leaked tokens shouldn't grant access forever. Callers (the token
  # creation form) can still pass `expires_at: nil` explicitly for "never".
  DEFAULT_EXPIRY = 90.days

  # A phone that is used keeps its login, one left in a drawer loses it: every
  # use pushes the expiry back out to this, so only DEVICE_IDLE_EXPIRY of
  # disuse ends a device session.
  DEVICE_IDLE_EXPIRY = 180.days

  # I4: MCP calls are frequent; only bump `last_used_at` at most this often
  # to avoid a DB write on every authenticated request.
  LAST_USED_THROTTLE = 5.minutes

  belongs_to :user

  validates :name, presence: true
  validates :token_digest, presence: true, uniqueness: true
  validates :kind, inclusion: { in: KINDS }

  scope :mcp, -> { where(kind: "mcp") }
  scope :device, -> { where(kind: "device") }

  attr_accessor :plain_token

  def self.generate(user, name:, expires_at: DEFAULT_EXPIRY.from_now, kind: "mcp")
    prefix = kind == "device" ? DEVICE_TOKEN_PREFIX : TOKEN_PREFIX
    plain = "#{prefix}#{SecureRandom.hex(32)}"
    token = user.api_tokens.new(
      name: name,
      kind: kind,
      token_digest: digest_for(plain),
      expires_at: expires_at
    )
    token.plain_token = plain
    token.save!
    token
  end

  def self.issue_device!(user, name:, client_version: nil)
    token = generate(user, name: name.to_s.truncate(80).presence || "Android",
                           expires_at: DEVICE_IDLE_EXPIRY.from_now, kind: "device")
    token.update_columns(client_version: client_version.to_s.truncate(40)) if client_version.present?
    token
  end

  # Returns the owning user, or nil. `kind` is required to match: an MCP token
  # presented to the app API (or the reverse) is simply not a credential there.
  def self.authenticate(plain, kind: "mcp")
    find_valid(plain, kind: kind)&.user
  end

  def self.find_valid(plain, kind:)
    return nil if plain.blank?

    token = find_by(token_digest: digest_for(plain), kind: kind)
    return nil unless token
    return nil if token.expired?

    token.touch_last_used!
    token
  end

  def self.digest_for(plain)
    Digest::SHA256.hexdigest(plain.to_s)
  end

  def device? = kind == "device"

  def expired?
    expires_at.present? && expires_at <= Time.current
  end

  # I4: write-amplification guard — skip the UPDATE if we touched this
  # recently (e.g. rapid MCP tool calls in the same session).
  def touch_last_used!
    return if last_used_at.present? && last_used_at > LAST_USED_THROTTLE.ago

    changes = { last_used_at: Time.current }
    changes[:expires_at] = DEVICE_IDLE_EXPIRY.from_now if device?
    update_columns(changes)
  end

  def masked_preview
    prefix = device? ? DEVICE_TOKEN_PREFIX : TOKEN_PREFIX
    "#{prefix}…#{token_digest.last(6)}"
  end
end
