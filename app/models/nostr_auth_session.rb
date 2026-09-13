# frozen_string_literal: true

class NostrAuthSession < ApplicationRecord
  LISTENER_LEASE = 30.seconds

  # H2: temp_privkey is the session's ephemeral NIP-46 signing key and
  # `secret` is the pairing/auth secret exchanged with the signer — both
  # sensitive even though short-lived. See
  # config/initializers/active_record_encryption.rb.
  encrypts :temp_privkey, :secret

  FLOWS = %w[nostrconnect bunker].freeze

  validates :session_id, presence: true, uniqueness: true
  validates :temp_pubkey, presence: true
  validates :temp_privkey, presence: true
  validates :relay_url, presence: true
  validates :expires_at, presence: true
  validates :flow, inclusion: { in: FLOWS }
  # Only the nostrconnect flow depends on the secret: it is the sole thing
  # binding that handshake to this browser, so it must exist. A bunker:// URI
  # may legitimately carry none — there the signer is pinned from the URI
  # instead, and the secret is at most an extra token the signer asked for.
  validates :secret, presence: true, if: :nostrconnect?
  validates :signer_pubkey, presence: true, if: :bunker?

  def nostrconnect? = flow != "bunker"
  def bunker? = flow == "bunker"

  scope :active, -> { where("expires_at > ?", Time.current).where(consumed_at: nil) }
  scope :expired, -> { where("expires_at <= ?", Time.current) }

  # relay_url stores a JSON array of relay URLs (backwards-compatible with single string)
  def relay_urls
    parsed = JSON.parse(relay_url)
    parsed.is_a?(Array) ? parsed : [parsed]
  rescue JSON::ParserError
    [relay_url]
  end

  def expired?
    expires_at <= Time.current
  end

  def authenticated?
    authenticated_pubkey.present? && authenticated_user_pubkey.present?
  end

  def self.cleanup_expired!
    expired.delete_all
  end

  def claim_listener!
    token = SecureRandom.hex(16)
    claimed = self.class.where(id: id, consumed_at: nil)
      .where("expires_at > ?", Time.current)
      .where("listener_started_at IS NULL OR listener_started_at < ?", LISTENER_LEASE.ago)
      .update_all(listener_started_at: Time.current, listener_token: token) == 1
    claimed ? token : nil
  end

  def renew_listener_lease!(token)
    self.class.where(id: id, listener_token: token, consumed_at: nil)
      .where("expires_at > ?", Time.current)
      .update_all(listener_started_at: Time.current) == 1
  end

  def release_listener!(token)
    self.class.where(id: id, listener_token: token)
      .update_all(listener_started_at: nil, listener_token: nil)
  end

  def consume!
    update!(consumed_at: Time.current, temp_privkey: "consumed", secret: "consumed", auth_url: nil,
      pending_rpc_id: nil, listener_started_at: nil, listener_token: nil)
  end
end
