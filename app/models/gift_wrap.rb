# frozen_string_literal: true

# Ledger of inbound kind-1059 gift wraps, one row per (account, wrap).
#
# This exists purely to make decryption idempotent. The same wrap arrives from
# every relay in the account's inbox list, and each one costs TWO nip44_decrypt
# round-trips to the user's phone — so "have we already paid for this wrap?" has
# to be a cheap, durable question.
class GiftWrap < ApplicationRecord
  include StatusTransitions

  belongs_to :account

  # MariaDB reports a `json` column as `longtext` (it is LONGTEXT plus a
  # json_valid CHECK), so ActiveRecord types it as Text and would store a Hash as
  # Ruby's `{"a"=>1}` inspect form — which then fails the constraint. Every json
  # column in this app has to be declared explicitly; see Post for the precedent.
  attribute :relays, :json, default: -> { [] }
  attribute :wrap_event, :json

  # Retryable failures (signer offline, socket dropped) get this many goes before
  # we give up and stop spending signer round-trips on them.
  MAX_ATTEMPTS = 5

  # A row left `decrypting` this long belongs to a worker that died.
  STUCK_AFTER = 10.minutes

  # Distinct relays remembered per wrap. Bounded because the list is written from
  # relay input and only ever read as a small set of reply targets.
  MAX_OBSERVED_RELAYS = 8

  enum :status, {
    pending: "pending",
    decrypting: "decrypting",
    decoded: "decoded",
    undecryptable: "undecryptable",
    rejected: "rejected"
  }, validate: true

  validates :wrap_id, presence: true, format: { with: /\A[0-9a-f]{64}\z/ }

  # Newest first: the inbox is useful within seconds of a backfill starting.
  scope :queue, -> { pending.order(wrap_created_at: :desc) }
  scope :stuck, -> { decrypting.where(updated_at: ..STUCK_AFTER.ago) }
  scope :unresolved, -> { where(status: %w[pending decrypting]) }

  # Claim for decryption. Atomic, so a sweeper requeue racing a fresh job cannot
  # produce two workers spending signer calls on the same wrap.
  def claim!
    transition_status(from: :pending, to: :decrypting)
  end

  # Wrap successfully turned into a message. Drop the cached event: it was only
  # kept so a retry after the signer was offline needed no refetch.
  #
  # Named `decode!` rather than `decoded!` so it does not shadow the zero-arg
  # bang setter the status enum already generates.
  def decode!(message)
    update!(status: "decoded", message_id: message.id, wrap_event: nil, last_error: nil)
  end

  # Malformed, hostile, or a rumor kind we do not render — a retry cannot help, so
  # never spend another signer round-trip on it.
  #
  # Keeps `wrap_event`, unlike decode!. A rejection is the one case where the
  # cached event still has value: it is the only way to find out WHY something was
  # dropped, and a later version that understands more rumor kinds can reprocess
  # it without refetching. Rejected wraps are a small minority by definition.
  def reject!(reason)
    update!(status: "rejected", last_error: reason.to_s)
  end

  # Retryable: leave it queued unless it has exhausted its attempts.
  def defer!(error)
    self.attempts += 1
    self.last_error = error.to_s.truncate(240)
    self.status = attempts >= MAX_ATTEMPTS ? "undecryptable" : "pending"
    save!
  end

  # Note that we saw this wrap on one more relay.
  #
  # The same wrap arrives from every relay we listen on, and `create_or_find_by!`
  # runs its block only on creation — so without this the second and later
  # sightings would be thrown away, and `relays` would record one arbitrary relay
  # instead of the set. That set is the whole point: it is the evidence used to
  # decide where a reply is worth publishing.
  #
  # Cheap on the common path: an already-recorded relay writes nothing.
  def observed_on!(relay_url)
    url = relay_url.to_s.strip
    return if url.blank?

    current = Array(relays)
    return if current.include?(url)

    update_columns(relays: (current + [ url ]).first(MAX_OBSERVED_RELAYS), updated_at: Time.current)
  end

  def resolved? = %w[decoded undecryptable rejected].include?(status)
end
