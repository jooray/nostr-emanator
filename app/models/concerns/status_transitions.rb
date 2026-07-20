# frozen_string_literal: true

# Atomic, race-safe status transitions shared by Post and Repost.
#
# Both records are driven by background jobs that can run concurrently
# (a retried sign job racing the original, the recurring enqueue job racing an
# in-flight publish job). Plain `update!(status: …)` lets the loser of such a
# race stomp the winner's result — see audit findings C3 and M8.
module StatusTransitions
  extend ActiveSupport::Concern

  # Move `from` -> `to` only if the row is still in `from`. Returns true when
  # this caller won the transition. Reloads the record on success so callers
  # see the new state; on failure the in-memory record is refreshed too, so
  # `record.status` reflects whoever won.
  def transition_status(from:, to:, attributes: {})
    from_values = Array(from).map { |s| self.class.statuses.fetch(s.to_s) }
    changed = self.class
      .where(id: id, status: from_values)
      .update_all(attributes.merge(status: self.class.statuses.fetch(to.to_s), updated_at: Time.current))
    reload
    changed.positive?
  end

  # C3: only mark failed while still awaiting signature. If a concurrent signer
  # already moved the record to scheduled/published, leave it alone.
  def fail_if_awaiting_signature!(attributes = {})
    transition_status(from: :awaiting_signature, to: :failed, attributes: attributes)
  end

  # M8: claim the record for publishing. A fresh job may only claim a
  # `scheduled` record; an ActiveJob *retry* of the job that already claimed it
  # (executions > 1) is allowed to continue from `publishing`.
  def claim_for_publishing!(allow_resume: false)
    scheduled_value = self.class.statuses.fetch("scheduled")
    publishing_value = self.class.statuses.fetch("publishing")
    base = self.class.where(id: id)

    claimable = base.where(status: scheduled_value)
    claimable = if allow_resume
      claimable.or(base.where(status: publishing_value))
    else
      # A record left `publishing` by a dead worker may be re-claimed.
      claimable.or(base.where(status: publishing_value).where(updated_at: ..self.class::STALE_PUBLISHING_AFTER.ago))
    end

    claimed = claimable.update_all(status: publishing_value, updated_at: Time.current)
    reload
    claimed.positive?
  end
end
