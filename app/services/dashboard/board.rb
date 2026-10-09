# frozen_string_literal: true

module Dashboard
  # The press run, not a set of counters.
  #
  # The dashboard used to load four vanity totals (accounts / scheduled /
  # published / total posts) and render them above everything else. None of them
  # answered the question the product exists to answer — "did anything go wrong
  # while I was away?".
  #
  # What loads now, in the order the operator needs it: what needs a human right
  # now, what went out short, what goes out next, and what never went out. The
  # web dashboard and the native app read the same board, so they can never
  # disagree about what needs attention.
  class Board
    RECENT_WINDOW = 7.days

    def initialize(user)
      @user = user
      @account_ids = user.accounts.pluck(:id)
    end

    def has_accounts? = @account_ids.any?

    # Posts and reposts together, because the rail's "awaiting signature" reading
    # counts both and this is the section it points at. A repost waiting on a tap
    # is the same interruption as a post waiting on one — it is just a different
    # identity asking.
    def waiting
      @waiting ||= (
        Post.where(account_id: @account_ids, status: :awaiting_signature)
            .includes(:account, :reposts).to_a +
        Repost.where(account_id: @account_ids, status: %i[awaiting_signature pending_signature])
              .includes(:account, :post).to_a
      ).sort_by { |record| record.scheduled_at || Time.current }.first(10)
    end

    # Only deliveries that actually failed to reach the network. A relay
    # declining is ordinary on Nostr — surfacing 5-of-6 here trained the eye to
    # skip this section, which is the one thing an alarm cannot survive.
    # Graded in Ruby because publish_results is JSON, so it is windowed rather
    # than a full-history scan.
    def unreached
      @unreached ||= Post.where(account_id: @account_ids, status: :published)
                         .where(published_at: RECENT_WINDOW.ago..)
                         .includes(:account)
                         .order(published_at: :desc)
                         .select(&:delivery_alarming?)
                         .first(5)
    end

    # Scheduled only: anything awaiting a signature is already listed above, and
    # listing it twice made the same row appear in two sections of one screen.
    def upcoming
      @upcoming ||= Post.where(account_id: @account_ids, status: :scheduled)
                        .where("posts.scheduled_at > ?", Time.current)
                        .includes(:account, :reposts)
                        .order(scheduled_at: :asc)
                        .limit(12)
                        .to_a
    end

    # Same set the rail counts. Listing only the posts is how "2 never went out"
    # could sit in the rail with an empty section under it: both failures were
    # reposts, and no surface in the app would show them.
    def failed
      @failed ||= (failed_posts.to_a + failed_reposts.to_a).sort_by(&:updated_at).reverse.first(5)
    end

    def failed_total
      @failed_total ||= failed_posts.count + failed_reposts.count
    end

    # Short pulls are already called out above; listing them again here made the
    # same row appear twice on one screen.
    def recent
      @recent ||= Post.where(account_id: @account_ids, status: :published)
                      .includes(:account)
                      .order(published_at: :desc)
                      .limit(8)
                      .reject(&:delivery_alarming?)
                      .first(6)
    end

    def held_count
      @held_count ||= Post.where(account_id: @account_ids, status: %i[scheduled awaiting_signature])
                          .where("posts.scheduled_at > ?", Time.current).count
    end

    private

    def failed_posts
      Post.where(account_id: @account_ids, status: :failed).includes(:account)
    end

    def failed_reposts
      Repost.where(account_id: @account_ids, status: :failed).includes(:account, :post)
    end
  end
end
