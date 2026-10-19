# frozen_string_literal: true

class Post < ApplicationRecord
  include StatusTransitions
  include RelayDelivery

  attribute :publish_results, :json
  attribute :signed_event, :json
  attribute :unsigned_event, :json
  attribute :version_history, :json, default: -> { [] }

  belongs_to :account
  has_many :reposts, dependent: :destroy

  enum :status, {
    draft: 0,
    awaiting_signature: 1,
    scheduled: 2,
    publishing: 3,
    published: 4,
    failed: 5
  }

  # A record stuck in `publishing` longer than this is considered abandoned
  # (worker died, retries exhausted) and is swept by SweepStuckRecordsJob.
  STALE_PUBLISHING_AFTER = 15.minutes
  # Signing waits on the user's phone; anything older than this is a dead end.
  STALE_SIGNING_AFTER = 20.minutes

  # A pasted or AI-written draft carries bare `nprofile1…` / `nevent1…`
  # identifiers. NIP-21 wants `nostr:`-prefixed URIs, and both our own preview
  # and every client key off that prefix, so canonicalise once on the way in
  # rather than at each of the places that read `content`. Idempotent.
  before_validation :normalize_nostr_references

  validates :content, presence: true
  validates :event_kind, inclusion: { in: [ 1 ] }
  # H8: a post without a scheduled time can never be picked up by
  # EnqueueScheduledPostsJob — it would sit "Scheduled" forever, silently.
  validates :scheduled_at, presence: true, if: -> { scheduled? || awaiting_signature? }

  scope :upcoming, -> { where(status: [ :scheduled, :awaiting_signature ]).where("scheduled_at > ?", Time.current).order(scheduled_at: :asc) }
  scope :past, -> { where(status: :published).order(published_at: :desc) }
  scope :stale_publishing, -> { where(status: :publishing).where(updated_at: ..STALE_PUBLISHING_AFTER.ago) }
  scope :stale_signing, -> { where(status: :awaiting_signature).where(updated_at: ..STALE_SIGNING_AFTER.ago) }

  def can_edit?
    draft? || awaiting_signature?
  end

  def can_schedule?
    draft? || awaiting_signature?
  end

  def can_sign?
    awaiting_signature? && unsigned_event.present?
  end

  # C4: `publishing` is included so a post abandoned mid-publish can be
  # recovered from the UI instead of spinning forever.
  def can_cancel?
    awaiting_signature? || scheduled? || failed? || publishing?
  end

  # A reply is sent the moment it is signed, never scheduled: the scheduler
  # builds a plain note, so rescheduling one would drop its reply tags.
  def can_reschedule?
    !is_reply? && (awaiting_signature? || scheduled? || failed?)
  end

  def can_retry_publish?
    (failed? || publishing?) && signed_event.present?
  end

  def can_rebroadcast?
    published? && signed_event.present?
  end

  def cancel!
    transaction do
      reposts.destroy_all
      update!(
        status: :draft,
        scheduled_at: nil,
        unsigned_event: nil,
        signed_event: nil,
        event_id: nil
      )
    end
  end

  def reschedule_reset!
    repost_account_ids = reposts.pluck(:account_id)
    transaction do
      reposts.destroy_all
      update!(
        status: :draft,
        scheduled_at: nil,
        unsigned_event: nil,
        signed_event: nil,
        event_id: nil
      )
    end
    repost_account_ids
  end

  # Edit content (and anything else permitted) the way every surface must:
  # keep the version history, and — C5 — throw away a signature request that
  # would otherwise publish the OLD text. Returns :updated, :invalidated or
  # false (validation failed; errors are on the record).
  def apply_edit!(attributes)
    attributes = attributes.to_h.stringify_keys
    content_changed = attributes.key?("content") && content != attributes["content"]

    if content_changed
      self.version_history = (version_history || []) + [ { content: content, changed_at: Time.current.iso8601 } ]
    end

    invalidated = content_changed && awaiting_signature?
    assign_attributes(status: :draft, unsigned_event: nil, signed_event: nil, event_id: nil) if invalidated

    return false unless update(attributes)

    if invalidated
      # Repost events embed the original event, so they are stale too.
      reposts.update_all(
        status: Repost.statuses[:pending_signature],
        unsigned_event: nil, signed_event: nil, event_id: nil,
        updated_at: Time.current
      )
    end
    invalidated ? :invalidated : :updated
  end

  # Replies skip scheduling: build the event now and sign it immediately.
  # The caller has checked the account has a signer.
  def start_reply_signing!
    unsigned = Nostr::EventSignerService.new.build_unsigned_reply(
      content: content,
      pubkey: account.pubkey_hex,
      created_at: Time.current,
      parent_event_id: reply_to_event_id,
      parent_author_pubkey: reply_to_pubkey,
      root_event_id: root_event_id
    )
    update!(unsigned_event: unsigned, scheduled_at: Time.current, status: :awaiting_signature)
    SignPostJob.perform_later(id)
  end

  def can_retry_sign?
    (awaiting_signature? || (failed? && signed_event.blank?)) && unsigned_event.present?
  end

  # A failed note is rebuilt rather than re-signed as it was. Feeds are sorted
  # by created_at, so a note signed with the time its first attempt failed
  # would go out already buried: nobody saw it then, and nobody would see it
  # now. A reply is dated now; a note keeps its hour while that is still ahead.
  def retry_signing!
    return SignPostJob.perform_later(id) unless failed?

    self.publish_results = nil
    rebuild_and_sign!
  end

  # A signed note that reached no relay and is older than this is signed again,
  # dated now, rather than sent as it was: the same burial as above.
  RESIGN_AFTER = 15.minutes

  def resign_on_retry?
    failed? && delivery_ok_count.zero? && account.has_signer? &&
      signed_event.present? && Time.at(signed_event["created_at"].to_i) < RESIGN_AFTER.ago
  end

  # Returns :sign when the note went back to the signer, :publish otherwise.
  def retry_publishing!
    if resign_on_retry?
      assign_attributes(signed_event: nil, event_id: nil, publish_results: nil)
      rebuild_and_sign!
      return :sign
    end

    update!(status: :scheduled, publish_results: nil)
    PublishPostJob.perform_later(id)

    reposts.failed.each do |repost|
      repost.update!(status: :scheduled, publish_results: nil)
      PublishRepostJob.perform_later(repost.id)
    end
    :publish
  end

  # Everything of this user's that never went out, posts and reposts alike —
  # both are counted by the same "never went out" reading, so both are cleared
  # by the same button. Returns how many records were removed.
  def self.discard_failed_for!(user, account_id: nil)
    posts = joins(:account).where(accounts: { user_id: user.id }, posts: { status: :failed })
    reposts = Repost.joins(:account).where(accounts: { user_id: user.id }, reposts: { status: :failed })
    if account_id.present?
      posts = posts.where(account_id: account_id)
      reposts = reposts.where(account_id: account_id)
    end

    count = posts.count + reposts.count
    posts.destroy_all
    reposts.destroy_all
    count
  end

  private

  def rebuild_and_sign!
    is_reply? ? start_reply_signing! : redate_and_sign!
  end

  # Reposts embed the note's event, so a re-dated note invalidates every one
  # not yet out. Each keeps its own delay after the note's new time; reposts the
  # sweeper failed while the note waited come back with it.
  def redate_and_sign!
    signer = Nostr::EventSignerService.new
    at = [ scheduled_at, Time.current ].compact.max
    unsigned = signer.build_unsigned_note(content: content, kind: event_kind, pubkey: account.pubkey_hex, created_at: at)

    transaction do
      update!(unsigned_event: unsigned, scheduled_at: at, status: :awaiting_signature)
      reposts.where.not(status: :published).includes(:account).find_each do |repost|
        repost_at = at + repost.delay_minutes.to_i.minutes
        repost.update!(
          unsigned_event: signer.build_unsigned_repost(original_event: unsigned, pubkey: repost.account.pubkey_hex, created_at: repost_at),
          scheduled_at: repost_at, signed_event: nil, event_id: nil,
          status: :awaiting_signature, publish_results: nil
        )
      end
    end
    SignPostJob.perform_later(id)
  end

  def normalize_nostr_references
    return unless will_save_change_to_content?

    self.content = Nostr::ContentRefs.normalize(content)
  end
end
