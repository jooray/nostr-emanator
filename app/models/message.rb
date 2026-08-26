# frozen_string_literal: true

# One direct message, inbound or outbound.
#
# Bodies are stored decrypted and encrypted at rest: unwrapping a gift wrap costs
# two round-trips to the user's signer, so re-decrypting per thread view would be
# unusable. Because the encryption is non-deterministic there is deliberately no
# SQL search over content — do not be tempted into `deterministic: true`, which
# would make message bodies equality-searchable by anyone holding the database.
class Message < ApplicationRecord
  # Only `transition_status` is used here (concurrent decrypt and send jobs claim
  # rows). The publish helpers the concern also mixes in are Post/Repost-specific
  # and would raise KeyError if called on a Message.
  include StatusTransitions

  belongs_to :conversation
  belongs_to :account
  belongs_to :user

  # Declared explicitly: MariaDB reports json columns as longtext, so without this
  # ActiveRecord stores a Hash as its Ruby inspect form and the json_valid CHECK
  # rejects it.
  attribute :publish_results, :json

  # serialize before encrypts, per the ActiveRecord::Encryption contract for
  # serialized attributes.
  serialize :file_metadata, coder: JSON
  serialize :raw_tags, coder: JSON

  encrypts :content
  encrypts :subject
  encrypts :file_metadata
  encrypts :raw_tags

  CHAT_KIND = 14
  FILE_KIND = 15
  LEGACY_KIND = 4
  KINDS = [ LEGACY_KIND, CHAT_KIND, FILE_KIND ].freeze

  STALE_SENDING_AFTER = 15.minutes

  enum :status, {
    received: "received",
    pending: "pending", sealing: "sealing", wrapping: "wrapping",
    publishing: "publishing", sent: "sent", failed: "failed"
  }, validate: true

  # Not `in`/`out` as predicate names: Object#in? already exists in ActiveSupport.
  enum :direction, { inbound: "in", outbound: "out" }, validate: true

  validates :rumor_id, presence: true, format: { with: /\A[0-9a-f]{64}\z/ }
  validates :sender_pubkey, presence: true, format: { with: /\A[0-9a-f]{64}\z/ }
  validates :kind, inclusion: { in: KINDS }
  validates :sort_at, presence: true
  validate :legacy_sends_require_acknowledgement

  scope :chronological, -> { order(:sort_at, :id) }
  scope :newest_first, -> { order(sort_at: :desc, id: :desc) }
  scope :stale_sending, -> { where(status: %w[sealing wrapping publishing], updated_at: ..STALE_SENDING_AFTER.ago) }

  # A hostile sender can date a rumor years into the future and pin itself to the
  # top of the inbox forever. Display their timestamp, but order by this.
  def self.sort_at_for(rumor_created_at, seen_at = Time.current)
    [ rumor_created_at || seen_at, seen_at ].min
  end

  def file_metadata_hash = file_metadata || {}
  def tags = raw_tags || []

  # Rebuild the exact unsigned rumor this row was created from.
  #
  # The row stores every field that goes into the NIP-01 id, so this is
  # deterministic — the send job must not re-derive a rumor whose id differs from
  # the one already indexed, or the self-copy would arrive as a second message.
  def rumor
    {
      "pubkey" => sender_pubkey,
      "created_at" => rumor_created_at.to_i,
      "kind" => kind,
      "tags" => tags,
      "content" => content,
      "id" => rumor_id
    }
  end

  def chat? = kind == CHAT_KIND
  def file? = kind == FILE_KIND
  def legacy? = kind == LEGACY_KIND

  # Sent to relays the recipient never designated for DMs, because they have
  # published no kind 10050. Still a gift wrap — the sender stays hidden — but
  # delivery depends on their client reading kind 1059 broadly, and a client with
  # no NIP-17 support at all (Primal, Damus) will never look.
  #
  # `observed` is included because the recipient still published no inbox — but
  # its note says something much weaker than the other two, because it is a relay
  # we watched their own messages arrive on rather than a guess.
  def best_effort_delivery? = %w[nip65 fallback observed].include?(delivery_tier)

  def delivery_note
    case delivery_tier
    when "nip65"    then "Sent to their public relays — they have no DM inbox, so it may not arrive"
    when "fallback" then "Sent to popular relays — they have no relay list at all, so it may not arrive"
    when "observed" then "Sent to the relays their own messages reach us on — they have no DM inbox, " \
                         "but their client is reading there"
    end
  end

  # A legacy message we sent, as a deliberate downgrade. Drives the permanent
  # "metadata was public" badge — this must never be a transient warning.
  def legacy_downgrade? = legacy? && outbound?

  def sending? = %w[pending sealing wrapping publishing].include?(status)

  def can_retry? = outbound? && failed?

  # What the user is actually giving up, in one place so every warning surface
  # says the same thing.
  LEGACY_DOWNGRADE_RISKS = [
    "Anyone watching the relays can see that you messaged this person, and when.",
    "Only the message text is encrypted — the sender and recipient are public.",
    "NIP-04 encryption is unauthenticated, so the ciphertext can be tampered with."
  ].freeze

  private

  # Kind 4 is only ever sent as an explicit, acknowledged downgrade for a
  # recipient who has published no kind 10050 and so cannot receive NIP-17 at all.
  #
  # Requiring the acknowledgement at the model layer — rather than trusting the
  # composer to ask — means a future code path cannot quietly start leaking the
  # social graph because it forgot the confirm step.
  def legacy_sends_require_acknowledgement
    return unless legacy_downgrade?
    return if legacy_downgrade_acked_at.present?

    errors.add(:base, "a legacy NIP-04 message can only be sent after the sender " \
                      "acknowledges that its metadata is public")
  end
end
