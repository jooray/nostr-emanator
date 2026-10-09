# frozen_string_literal: true

module Dashboard
  # The lamp bank at the foot of the rail (web) and the badges on the app's
  # tabs. Four readings the operator needs before anything else, in the order
  # they matter:
  #
  #   identities  — how many accounts this login speaks for
  #   waiting     — how many events are sitting on a human right now
  #   short       — published but reached fewer relays than they were sent to
  #   failed      — never went out at all
  #
  # `short` has to be computed in Ruby because publish_results is a JSON blob,
  # so it is scoped to a recent window rather than the whole history: a short
  # pull from three months ago is not a thing anyone is going to act on, and
  # counting it would cost a full scan.
  module StationStatus
    SHORT_DELIVERY_WINDOW = 7.days

    def self.for(user)
      account_ids = user.accounts.pluck(:id)

      recent_published = Post.where(account_id: account_ids, status: :published)
                             .where(published_at: SHORT_DELIVERY_WINDOW.ago..)
                             .select(:id, :publish_results, :status)

      {
        identities: account_ids.size,
        waiting: Post.where(account_id: account_ids, status: :awaiting_signature).count +
                 Repost.where(account_id: account_ids, status: %i[awaiting_signature pending_signature]).count,
        short: recent_published.count(&:delivery_alarming?),
        failed: Post.where(account_id: account_ids, status: :failed).count +
                Repost.where(account_id: account_ids, status: :failed).count
      }
    end
  end
end
