# frozen_string_literal: true

# A NIP-17 (or legacy NIP-04) DM room, owned by one paired account.
#
# The room's identity is its participant set — NIP-17 has no room id — so adding
# or removing a participant produces a different `participants_key` and therefore
# a different room with clean history. That is the spec's behaviour, not a
# limitation to work around.
class Conversation < ApplicationRecord
  belongs_to :user
  belongs_to :account
  has_many :messages, dependent: :destroy

  # Room titles are user content. See CreateConversations for why these are text.
  encrypts :subject
  encrypts :last_message_preview

  attribute :participant_pubkeys, :json, default: -> { [] }

  enum :protocol, { nip17: "nip17", nip04: "nip04" }, validate: true

  # `known` reaches the main inbox; `request` waits for the user to accept;
  # `muted` is hidden outright.
  enum :classification, { known: "known", request: "request", muted: "muted" }, validate: true

  # Why a sender was let through, in the order SenderClassifier evaluates them.
  REASONS = %w[self own_follow sibling_follow wot replied manual unclassified].freeze

  validates :participants_key, presence: true, format: { with: /\A[0-9a-f]{64}\z/ }
  validates :classification_reason, inclusion: { in: REASONS }, allow_nil: true

  scope :active, -> { where(archived: false) }
  scope :recent_first, -> { order(last_message_at: :desc) }
  scope :with_unread, -> { where("unread_count > 0") }

  # Reply targets and composer behaviour differ per protocol, and we never send
  # kind 4 — so a legacy thread is deliberately a separate room.
  def legacy? = nip04?

  def group? = participant_pubkeys.size > 2

  def unread? = unread_count.positive?

  # The other side of a 1:1. Groups have no single peer.
  def peer_pubkeys
    participant_pubkeys - [ account.pubkey_hex ]
  end

  # Newest `subject` tag wins (NIP-17). Older messages arriving late must not
  # revert a title the room has already moved past.
  def apply_subject(new_subject, seen_at)
    return if new_subject.blank?
    return if subject_updated_at.present? && seen_at <= subject_updated_at

    update!(subject: new_subject, subject_updated_at: seen_at)
  end

  # A manual accept/block is sticky: automatic reclassification must never
  # silently revert what the user decided by hand.
  def classify!(classification, reason)
    return false if classification_locked?

    update!(classification: classification, classification_reason: reason, classified_at: Time.current)
  end

  def accept!
    update!(classification: "known", classification_reason: "manual",
            classification_locked: true, classified_at: Time.current)
  end

  def block!
    update!(classification: "muted", classification_reason: "manual",
            classification_locked: true, classified_at: Time.current)
  end
end
