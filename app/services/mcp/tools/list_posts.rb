# frozen_string_literal: true

module Mcp
  module Tools
    class ListPosts < Base
      DEFAULT_LIMIT = 50
      STATUSES = Post.statuses.keys.freeze

      def self.description
        <<~DESC.strip
          List the user's posts, optionally filtered to one account or one status.
          Set upcoming=true to get only future scheduled posts (status scheduled or
          awaiting_signature, scheduled_at in the future), ordered soonest-first —
          this is the "what is queued to go out" feed. Otherwise posts are returned
          newest-first by creation time. Each post includes its account, status,
          content, scheduled/published times, and its reposts.
        DESC
      end

      def self.input_schema
        {
          type: "object",
          additionalProperties: false,
          properties: {
            account_id: { type: "integer", description: "Restrict to a single account you manage." },
            status: { type: "string", enum: STATUSES, description: "Restrict to one status." },
            upcoming: { type: "boolean", description: "If true, only future scheduled posts, soonest first. Default false." },
            since: { type: "string", description: "ISO8601; lower bound on scheduled_at (upcoming) or created_at." },
            until: { type: "string", description: "ISO8601; upper bound on scheduled_at (upcoming) or created_at." },
            limit: { type: "integer", minimum: 1, maximum: MAX_LIMIT, description: "Max posts. Default 50, max 200." },
            offset: { type: "integer", minimum: 0, description: "Offset for pagination." }
          }
        }
      end

      def call
        scope = user_posts.includes(:account, reposts: :account)

        if args[:account_id].present?
          account = find_user_account!(args[:account_id])
          scope = scope.where(account_id: account.id)
        end

        if args[:status].present?
          status = args[:status].to_s
          raise InvalidParams, "unknown status: #{status}" unless STATUSES.include?(status)
          scope = scope.where(status: status)
        end

        upcoming = fetch_bool(:upcoming, default: false)
        time_column = upcoming ? :scheduled_at : :created_at

        if upcoming
          scope = scope.where(status: [:scheduled, :awaiting_signature])
            .where("posts.scheduled_at > ?", Time.current)
            .order(scheduled_at: :asc)
        else
          scope = scope.order(created_at: :desc)
        end

        # Qualify with the posts table: reposts also has scheduled_at, and the
        # eager-load join would make a bare column reference ambiguous.
        since = fetch_time(:since, default: nil)
        until_t = fetch_time(:until, default: nil)
        scope = scope.where("posts.#{time_column} >= ?", since) if since
        scope = scope.where("posts.#{time_column} <= ?", until_t) if until_t

        limit = fetch_int(:limit, default: DEFAULT_LIMIT, min: 1, max: MAX_LIMIT)
        offset = fetch_int(:offset, default: 0, min: 0, max: 1_000_000)

        posts = scope.limit(limit).offset(offset).to_a
        { posts: posts.map { |p| serialize_post(p) }, count: posts.size }
      end
    end
  end
end
