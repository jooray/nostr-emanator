# frozen_string_literal: true

# One NIP-RS read-state blob (kind 30078, `d: read-state:<slot-id>`).
#
# There is no standard for syncing DM read state across Nostr clients: three NIPs
# were proposed and two withdrawn by their own author, most recently because
# clients slice notifications into different views so there is nothing shared to
# mark as read. NIP-RS is the one rigorous spec, and its merge rule is what makes
# concurrent devices safe — a grow-only max register:
#
#   effective[context] = max(timestamp) across every slot
#
# A timestamp is therefore NEVER lowered. That also means mark-as-unread cannot be
# expressed, which the spec calls out as deliberate.
#
# `own: true` is this installation's slot (the only one we publish); other rows
# are peers imported from relays. Slots are per account, because the spec asks
# multi-identity clients to use distinct ids per pubkey.
#
# https://github.com/block/buzz/blob/master/docs/nips/NIP-RS.md
class ReadStateSlot < ApplicationRecord
  belongs_to :account

  # serialize before encrypts, per the ActiveRecord::Encryption contract.
  serialize :contexts, coder: JSON
  encrypts :contexts

  KIND = 30_078
  D_TAG_PREFIX = "read-state:"
  # Lets relays filter our blobs without dumping every kind-30078 we own.
  TOPIC_TAG = "read-state"

  MAX_CONTEXTS = 10_000
  MAX_TIMESTAMP = 4_294_967_295
  # Contexts older than this are pruned before publishing, to stay well under the
  # spec's 64 KB event ceiling.
  HORIZON = 7.days
  # A cursor advances on every thread open and each publish costs an encrypt plus
  # a sign, so coalesce bursts.
  DEBOUNCE = 8.seconds

  validates :slot_id, presence: true, format: { with: /\A[0-9a-f]{32}\z/ }
  validates :client_id, length: { in: 1..64 }, allow_nil: true

  scope :own_slot, -> { where(own: true) }
  scope :peers, -> { where(own: false) }
  scope :due_for_publish, -> { own_slot.where(dirty: true).where(publish_after: ..Time.current) }

  # 32 hex chars, stable per installation. Per-slot ids are what stop two devices
  # from clobbering each other's replaceable event.
  def self.generate_slot_id = SecureRandom.hex(16)

  def d_tag = "#{D_TAG_PREFIX}#{slot_id}"

  def context_map = contexts || {}

  # Merge `updates` under the max rule. Returns true if anything actually moved,
  # so callers only mark the slot dirty when there is something new to publish.
  def merge_contexts!(updates)
    merged = context_map.dup
    changed = false

    updates.each do |context, timestamp|
      timestamp = timestamp.to_i
      next unless timestamp.between?(0, MAX_TIMESTAMP)
      next if merged[context].to_i >= timestamp

      merged[context] = timestamp
      changed = true
    end

    return false unless changed

    update!(contexts: prune(merged))
    true
  end

  def mark_dirty!(now: Time.current)
    update!(dirty: true, publish_after: now + DEBOUNCE)
  end

  private

  # Drop contexts outside the fetch horizon, then hard-cap by recency so a
  # pathological account cannot exceed the spec's limit.
  def prune(map)
    cutoff = HORIZON.ago.to_i
    kept = map.select { |_context, timestamp| timestamp.to_i >= cutoff }
    kept = kept.sort_by { |_context, timestamp| -timestamp.to_i }.first(MAX_CONTEXTS).to_h if kept.size > MAX_CONTEXTS
    kept
  end
end
