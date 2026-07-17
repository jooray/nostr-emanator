# frozen_string_literal: true

class User < ApplicationRecord
  attribute :settings, :json, default: -> { {} }

  has_many :accounts, dependent: :destroy
  has_many :api_tokens, dependent: :destroy

  validates :npub, presence: true, uniqueness: true
  validates :pubkey_hex, presence: true, uniqueness: true

  def display_name_or_npub
    display_name.presence || username.presence || npub.truncate(20)
  end

  def theme
    settings&.dig("theme") || "system"
  end

  def theme=(value)
    self.settings = (settings || {}).merge("theme" => value)
  end

  def timezone
    settings&.dig("timezone") || "UTC"
  end

  def timezone=(value)
    self.settings = (settings || {}).merge("timezone" => value)
  end

  def event_viewer
    settings&.dig("event_viewer") || "njump"
  end

  def event_viewer=(value)
    self.settings = (settings || {}).merge("event_viewer" => value)
  end

  def custom_relays
    settings&.dig("custom_relays") || []
  end

  def custom_relays=(value)
    relays = value.is_a?(Array) ? value : value.to_s.split("\n")
    relays = relays.map(&:strip).select { |r| r.start_with?("wss://", "ws://") }
    self.settings = (settings || {}).merge("custom_relays" => relays)
  end
end
