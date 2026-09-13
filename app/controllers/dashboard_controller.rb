# frozen_string_literal: true

class DashboardController < ApplicationController
  # The press run, not a set of counters.
  #
  # This used to load four vanity totals (accounts / scheduled / published /
  # total posts) and render them above everything else. None of them answered
  # the question the product exists to answer — "did anything go wrong while I
  # was away?" — and the failed-posts card sat below them and below the upcoming
  # list, roughly three mobile screens down.
  #
  # What loads now, in the order the operator needs it: what needs a human right
  # now, what went out short, what goes out next, and what never went out.
  RECENT_WINDOW = 7.days

  def index
    account_ids = current_user.accounts.pluck(:id)

    # Posts and reposts together, because the rail's "awaiting signature" reading
    # counts both and this is the section it points at. A repost waiting on a tap
    # is the same interruption as a post waiting on one — it is just a different
    # identity asking.
    @waiting = (
      Post.where(account_id: account_ids, status: :awaiting_signature)
          .includes(:account, :reposts).to_a +
      Repost.where(account_id: account_ids, status: %i[awaiting_signature pending_signature])
            .includes(:account, :post).to_a
    ).sort_by { |record| record.scheduled_at || Time.current }.first(10)

    # Only deliveries that actually failed to reach the network. A relay
    # declining is ordinary on Nostr — surfacing 5-of-6 here trained the eye to
    # skip this section, which is the one thing an alarm cannot survive.
    # Graded in Ruby because publish_results is JSON, so it is windowed rather
    # than a full-history scan.
    @unreached = Post.where(account_id: account_ids, status: :published)
                     .where(published_at: RECENT_WINDOW.ago..)
                     .includes(:account)
                     .order(published_at: :desc)
                     .select(&:delivery_alarming?)
                     .first(5)

    # Scheduled only: anything awaiting a signature is already listed above, and
    # listing it twice made the same row appear in two sections of one screen.
    @upcoming = Post.where(account_id: account_ids, status: :scheduled)
                    .where("posts.scheduled_at > ?", Time.current)
                    .includes(:account, :reposts)
                    .order(scheduled_at: :asc)
                    .limit(12)

    # Same set the rail counts. Listing only the posts is how "2 never went out"
    # could sit in the rail with an empty section under it: both failures were
    # reposts, and no surface in the app would show them.
    failed_posts = Post.where(account_id: account_ids, status: :failed).includes(:account)
    failed_reposts = Repost.where(account_id: account_ids, status: :failed).includes(:account, :post)
    @failed = (failed_posts.to_a + failed_reposts.to_a).sort_by(&:updated_at).reverse.first(5)
    @failed_total = failed_posts.count + failed_reposts.count

    # Short pulls are already called out above; listing them again here made the
    # same row appear twice on one screen.
    @recent = Post.where(account_id: account_ids, status: :published)
                  .includes(:account)
                  .order(published_at: :desc)
                  .limit(8)
                  .reject(&:delivery_alarming?)
                  .first(6)

    @held_count = Post.where(account_id: account_ids, status: %i[scheduled awaiting_signature])
                      .where("posts.scheduled_at > ?", Time.current).count
    @has_accounts = account_ids.any?
  end
end
