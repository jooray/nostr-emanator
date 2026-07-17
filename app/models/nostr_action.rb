# frozen_string_literal: true

class NostrAction < ApplicationRecord
  attribute :unsigned_event, :json
  attribute :signed_event, :json
  attribute :publish_results, :json

  belongs_to :account

  enum :action_type, { reaction: 0, follow: 1, mute: 2 }
  enum :status, { pending: 0, awaiting_signature: 1, processing: 2, publishing: 3, published: 4, failed: 5 }

  validates :target_pubkey, presence: true
  validates :target_event_id, presence: true, if: :reaction?

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
