# frozen_string_literal: true

class Account < ApplicationRecord
  attribute :settings, :json, default: -> { {} }
  attribute :write_relays, :json, default: -> { [] }

  belongs_to :user
  has_many :posts, dependent: :destroy
  has_many :reposts, dependent: :destroy
  has_many :nostr_actions, dependent: :destroy

  validates :pubkey_hex, presence: true
  validates :pubkey_hex, uniqueness: { scope: :user_id }

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

  def set_npub
    if pubkey_hex.present? && npub.blank?
      self.npub = Nostr::KeyConverter.hex_to_npub(pubkey_hex)
    end
  end
end
