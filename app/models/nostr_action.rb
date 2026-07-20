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

  validates :target_pubkey, presence: true, format: { with: HEX_32, message: "must be a 64-character lowercase hex pubkey" }
  validates :target_event_id, presence: true, if: :reaction?
  validates :target_event_id, format: { with: HEX_32, message: "must be a 64-character lowercase hex event id" }, allow_blank: true
  validates :target_event_kind, inclusion: { in: ALLOWED_TARGET_KINDS, message: "is not a supported event kind" }, allow_nil: true

  scope :reactions_for_event, ->(account_id, event_id) {
    where(account_id: account_id, action_type: :reaction, target_event_id: event_id).where.not(status: :failed)
  }

  scope :follows_for_pubkey, ->(account_id, pubkey) {
    where(account_id: account_id, action_type: :follow, target_pubkey: pubkey).where.not(status: :failed)
  }

  scope :mutes_for_pubkey, ->(account_id, pubkey) {
    where(account_id: account_id, action_type: :mute, target_pubkey: pubkey).where.not(status: :failed)
  }
end
