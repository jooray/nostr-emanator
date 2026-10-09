# frozen_string_literal: true

class NostrAction < ApplicationRecord
  attribute :unsigned_event, :json
  attribute :signed_event, :json
  attribute :publish_results, :json

  belongs_to :account

  enum :action_type, { reaction: 0, follow: 1, mute: 2 }
  enum :status, { pending: 0, awaiting_signature: 1, processing: 2, publishing: 3, published: 4, failed: 5 }

  # L2: target_event_id / target_pubkey / target_event_kind come straight from
  # the browser and end up inside an event we sign with the user's key, so they
  # are pinned to NIP-01 shapes (64 lowercase hex) and a kind allowlist before
  # anything is signed or published.
  HEX_32 = /\A[0-9a-f]{64}\z/
  ALLOWED_TARGET_KINDS = [ 1, 6, 7, 20, 1111, 9802, 30023 ].freeze

  validates :target_pubkey, presence: true, format: { with: HEX_32, message: :invalid_hex_pubkey }
  validates :target_event_id, presence: true, if: :reaction?
  validates :target_event_id, format: { with: HEX_32, message: :invalid_hex_event_id }, allow_blank: true
  validates :target_event_kind, inclusion: { in: ALLOWED_TARGET_KINDS, message: :unsupported_kind }, allow_nil: true

  scope :reactions_for_event, ->(account_id, event_id) {
    where(account_id: account_id, action_type: :reaction, target_event_id: event_id).where.not(status: :failed)
  }

  scope :follows_for_pubkey, ->(account_id, pubkey) {
    where(account_id: account_id, action_type: :follow, target_pubkey: pubkey).where.not(status: :failed)
  }

  scope :mutes_for_pubkey, ->(account_id, pubkey) {
    where(account_id: account_id, action_type: :mute, target_pubkey: pubkey).where.not(status: :failed)
  }

  # Like / follow / mute on behalf of an account, from the web or the app.
  # Returns [action, error]. An identical action already under way is returned
  # instead of a second one; a permanently failed one is revived for a retry.
  def self.request!(account, attrs)
    attrs = attrs.to_h.stringify_keys
    existing = account.nostr_actions.where.not(status: :failed)
    existing =
      case attrs["action_type"]
      when "reaction" then existing.reactions_for_event(account.id, attrs["target_event_id"]).first
      when "follow" then existing.follows_for_pubkey(account.id, attrs["target_pubkey"]).first
      when "mute" then existing.mutes_for_pubkey(account.id, attrs["target_pubkey"]).first
      end
    return [ existing, nil ] if existing

    action = account.nostr_actions.build(attrs)
    return [ nil, action.errors.full_messages.join(", ") ] unless action.save

    ProcessNostrActionJob.perform_later(action.id)
    [ action, nil ]
  rescue ArgumentError => e
    # An unknown action_type is an enum ArgumentError, not a validation error.
    [ nil, e.message ]
  rescue ActiveRecord::RecordNotUnique
    # M13: lost a race against a concurrent create for the same natural key
    # (account_id, action_type, target_event_id, target_pubkey) — reload the
    # row that won instead of 500ing. If it had permanently failed, resurrect
    # it for a retry rather than leaving the user stuck with no way to redo
    # the action from the UI they just used.
    winner = account.nostr_actions.find_by(attrs.slice("action_type", "target_event_id", "target_pubkey"))
    return [ nil, I18n.t("nostr_actions.duplicate") ] unless winner

    winner.retry! if winner.failed?
    [ winner, nil ]
  end

  def retryable?
    awaiting_signature? || (failed? && unsigned_event.present? && signed_event.blank?)
  end

  def retry!
    update!(status: :pending, error_message: nil, publish_results: nil)
    ProcessNostrActionJob.perform_later(id)
  end
end
