# frozen_string_literal: true

module Posts
  # The posts list with its account and status filters — the web Posts page and
  # the app's list are this one query.
  #
  # 300 posts across 19 identities used to arrive as one unfiltered, unsorted
  # stream; there was no way to answer "what failed?" or "what is queued for
  # Ember?" without reading the whole list.
  class Listing
    # The two states whose station reading counts reposts as well as posts.
    MERGED_REPOST_STATUSES = {
      "failed" => %i[failed],
      "awaiting_signature" => %i[awaiting_signature pending_signature]
    }.freeze

    attr_reader :account_filter, :status_filter

    def initialize(user, account: nil, status: nil)
      @user = user
      @account_filter = account.presence
      @status_filter = status.presence
    end

    def short_only? = @status_filter == "short"

    # Paginated, newest first. Mixed Post/Repost records for the merged filters.
    def page(number)
      if short_only?
        Kaminari.paginate_array(scope.select(&:delivery_alarming?)).page(number)
      elsif (reposts = reposts_for_filter).any?
        merged = (scope.to_a + reposts).sort_by(&:created_at).reverse
        Kaminari.paginate_array(merged).page(number)
      else
        scope.page(number)
      end
    end

    # Offered right where the failures are listed, scoped to the account filter
    # in view so it can never clear more than what is on screen — which means
    # counting the reposts it also clears.
    def failed_here
      return 0 unless @status_filter == "failed"

      narrow(Post.joins(:account).where(accounts: { user_id: @user.id }, posts: { status: :failed })).count +
        narrow(Repost.joins(:account).where(accounts: { user_id: @user.id }, reposts: { status: :failed })).count
    end

    private

    def scope
      scope = narrow(Post.joins(:account).where(accounts: { user_id: @user.id }).includes(:account, :reposts))
      # "short" is not a status — it is a delivery grade, and publish_results is
      # JSON, so it narrows to published here and is filtered in Ruby.
      scope =
        case @status_filter
        when "short" then scope.where(status: :published)
        when nil, "all" then scope
        else Post.statuses.key?(@status_filter) ? scope.where(status: @status_filter) : scope.none
        end
      scope.order(created_at: :desc)
    end

    # Reposts belong in these two lists, because the station readings count
    # them. The rail said "2 never went out" and the list said "No posts match
    # this filter" — both right about their own query, and the reading was
    # unreachable. A failed repost is a real failure: that identity never
    # reposted the note, and nothing else was going to say so.
    def reposts_for_filter
      statuses = MERGED_REPOST_STATUSES[@status_filter]
      return [] unless statuses

      narrow(Repost.joins(:account).where(accounts: { user_id: @user.id }, reposts: { status: statuses }))
        .includes(:account, :post).to_a
    end

    def narrow(relation)
      @account_filter ? relation.where(account_id: @account_filter) : relation
    end
  end
end
