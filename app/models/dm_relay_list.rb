# frozen_string_literal: true

# Cached kind-10050 DM relay list for a pubkey — ours or anyone we message.
#
# NIP-17 makes this mandatory in both directions: clients MUST publish gift wraps
# only to the recipient's 10050 relays, and a person with no 10050 "is not ready
# to receive messages and clients shouldn't try". So `missing` is a state the UI
# has to show, not an error to swallow — it is the single most common reason a
# NIP-17 DM silently never arrives.
class DmRelayList < ApplicationRecord
  # NIP-17 asks users to keep this list small (1-3) and clients not to fan out.
  MAX_RELAYS = 6
  STALE_AFTER = 6.hours
  # Re-checking a pubkey that has no list at all can be much lazier than
  # refreshing one that does.
  RECHECK_MISSING_AFTER = 24.hours

  # `missing: true` may only be set after a real, definitive negative — a fan-out
  # to the indexer relays AND to the pubkey's own NIP-65 write relays (where the
  # outbox model says their 10050 legitimately lives) all came back empty.
  #
  # Treating a mere cache miss as "no list" is the dangerous mistake here. Kind
  # 10050 is replaceable, so for our own accounts a false negative leads to
  # prompting the user to publish a list that overwrites the one their other
  # client already published. Everyone in nostrability#169 agreed on that one
  # point even where they disagreed on everything else: never overwrite an
  # existing 10050.
  def self.definitive_negative!(pubkey_hex, checked_at: Time.current)
    record = find_or_initialize_by(pubkey_hex: pubkey_hex.to_s.downcase)
    record.update!(missing: true, relays: [], fetched_at: checked_at, checked_at: checked_at)
    record
  end

  # Declared explicitly: MariaDB reports json columns as longtext, so without this
  # ActiveRecord stores a Hash as its Ruby inspect form and the json_valid CHECK
  # rejects it.
  attribute :relays, :json, default: -> { [] }
  attribute :raw_event, :json

  validates :pubkey_hex, presence: true, uniqueness: true, format: { with: /\A[0-9a-f]{64}\z/ }

  scope :stale, -> { where(fetched_at: ..STALE_AFTER.ago) }

  def self.for_pubkey(pubkey_hex)
    find_by(pubkey_hex: pubkey_hex.to_s.downcase)
  end

  # Can this pubkey actually receive a gift wrap from us?
  def deliverable? = !missing? && relays.any?

  def stale?
    return true if fetched_at.nil?

    fetched_at < (missing? ? RECHECK_MISSING_AFTER : STALE_AFTER).ago
  end
end
