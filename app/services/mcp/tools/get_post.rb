# frozen_string_literal: true

module Mcp
  module Tools
    class GetPost < Base
      def self.description
        "Fetch a single post you manage by id, with full content, status, " \
          "scheduled/published times, the published event id (if any), and all of its reposts."
      end

      def self.input_schema
        {
          type: "object",
          additionalProperties: false,
          required: ["post_id"],
          properties: {
            post_id: { type: "integer" }
          }
        }
      end

      def call
        post = find_user_post!(args[:post_id])
        { post: serialize_post(post) }
      end
    end
  end
end
