# frozen_string_literal: true

module Mcp
  module Tools
    class SearchPosts < Base
      DEFAULT_LIMIT = 25

      def self.description
        "Full-text (substring) search over the content of the user's posts, " \
          "newest first. Optionally restrict to a single account."
      end

      def self.input_schema
        {
          type: "object",
          additionalProperties: false,
          required: ["query"],
          properties: {
            query: { type: "string", description: "Text to match within post content." },
            account_id: { type: "integer", description: "Restrict to a single account you manage." },
            limit: { type: "integer", minimum: 1, maximum: MAX_LIMIT, description: "Default 25, max 200." }
          }
        }
      end

      def call
        query = args[:query].to_s.strip
        raise InvalidParams, "query required" if query.empty?

        scope = user_posts.includes(:account)
        if args[:account_id].present?
          account = find_user_account!(args[:account_id])
          scope = scope.where(account_id: account.id)
        end

        pattern = "%#{ActiveRecord::Base.sanitize_sql_like(query)}%"
        limit = fetch_int(:limit, default: DEFAULT_LIMIT, min: 1, max: MAX_LIMIT)

        posts = scope.where("content LIKE ?", pattern)
          .order(created_at: :desc)
          .limit(limit)
          .to_a

        { query: query, posts: posts.map { |p| serialize_post(p, include_reposts: false) }, count: posts.size }
      end
    end
  end
end
