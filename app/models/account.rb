# frozen_string_literal: true

class Account < ApplicationRecord
  attribute :settings, :json, default: -> { {} }
  attribute :write_relays, :json, default: -> { [] }

  # H2: the NIP-46 app private key is a long-lived signing-delegation
  # credential — Amber signs kind-1 notes without manual confirmation, so a
  # stolen plaintext value would mean silent, unlimited posting as this
  # account. See config/initializers/active_record_encryption.rb.
  encrypts :app_privkey

  belongs_to :user
  has_many :posts, dependent: :destroy
  has_many :reposts, dependent: :destroy
  has_many :nostr_actions, dependent: :destroy

  validates :pubkey_hex, presence: true
  validates :pubkey_hex, uniqueness: { scope: :user_id }
  validate :blossom_server_must_be_safe

  # Personality text is injected verbatim into every AI prompt; unbounded text
  # would let one account blow up (and pay for) every completion.
  MAX_PERSONALITY_LENGTH = 8_000
  validates :personality, length: { maximum: MAX_PERSONALITY_LENGTH }

  before_validation :set_npub, on: :create

  def display_name_or_npub
    display_name.presence || username.presence || npub&.truncate(20) || pubkey_hex.truncate(16)
  end

  def has_signer?
    signer_pubkey.present? && app_privkey.present?
  end

  # Blossom media server for this account, falling back to the global default.
  # Normalized to drop any trailing slash so we can append "/upload" etc.
  def blossom_server
    raw = settings&.dig("blossom_server").presence || Account.default_blossom_server
    raw.to_s.strip.sub(%r{/+\z}, "")
  end

  # Persisted via account_params (:blossom_server). Stored in the settings JSON.
  # Changing the server clears the per-server "/media unsupported" cache.
  def blossom_server=(value)
    normalized = value.to_s.strip.presence
    self.settings = (settings || {}).merge("blossom_server" => normalized)
    if settings["blossom_media_unsupported"].present? &&
       settings["blossom_media_unsupported"] != blossom_server
      settings.delete("blossom_media_unsupported")
    end
  end

  # Whether to attempt the BUD-05 /media endpoint for this account's server.
  # Defaults to true; set false (cached per-server) after a failed attempt.
  def blossom_media_supported?
    settings&.dig("blossom_media_unsupported") != blossom_server
  end

  def mark_media_unsupported!
    self.settings = (settings || {}).merge("blossom_media_unsupported" => blossom_server)
    save!
  end

  def self.default_blossom_server
    Rails.application.config_for(:emanator).dig(:blossom, :server)
  end

  private

  # H1: the per-account Blossom server is a URL the *server* connects to (and
  # PUTs attacker-chosen bytes at), so an unvalidated value is an SSRF primitive
  # against internal hosts. Only a public https endpoint is acceptable.
  def blossom_server_must_be_safe
    configured = settings&.dig("blossom_server").presence
    return if configured.blank?

    Security::UrlGuard.validate!(blossom_server, schemes: Security::UrlGuard.http_schemes)
  rescue Security::UrlGuard::UnsafeUrlError => e
    errors.add(:blossom_server, e.message)
  end

  def set_npub
    if pubkey_hex.present? && npub.blank?
      self.npub = Nostr::KeyConverter.hex_to_npub(pubkey_hex)
    end
  end
end
