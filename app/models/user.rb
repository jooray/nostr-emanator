# frozen_string_literal: true

class User < ApplicationRecord
  attribute :settings, :json, default: -> { {} }

  has_many :accounts, dependent: :destroy
  has_many :api_tokens, dependent: :destroy

  validates :npub, presence: true, uniqueness: true
  validates :pubkey_hex, presence: true, uniqueness: true
  validate :custom_relays_must_be_safe

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

  # H4: these URLs are opened by the server on every publish, so a scheme
  # prefix check is not enough — each one goes through Security::UrlGuard
  # (wss:// only in production, public addresses only). Unsafe entries are not
  # stored and are reported back to the user as a validation error.
  def custom_relays=(value)
    relays = value.is_a?(Array) ? value : value.to_s.split("\n")
    relays = relays.map { |r| r.to_s.strip }.reject(&:blank?)
    safe, @rejected_custom_relays = relays.partition { |r| Security::UrlGuard.safe_relay?(r) }
    self.settings = (settings || {}).merge("custom_relays" => safe)
  end

  private

  def custom_relays_must_be_safe
    Array(@rejected_custom_relays).each do |relay|
      errors.add(:custom_relays, "#{relay} is not usable: relays must be wss:// URLs on public hosts")
    end
  end
end
