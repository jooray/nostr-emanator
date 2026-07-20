# frozen_string_literal: true

module Mcp
  module Tools
    class CreateDraftPost < Base
      def self.description
        <<~DESC.strip
          Create a new draft post for one of the user's accounts. Optionally attach a
          suggested scheduled_at (ISO8601). The post is saved as a DRAFT only — it is
          NOT yet scheduled or published. To publish it automatically, call
          schedule_post with the returned post id (Amber signs kind-1 notes without
          manual approval). Use this to stage content for review, or pair it with
          schedule_post to draft and schedule in two steps.
        DESC
      end

      def self.input_schema
        {
          type: "object",
          additionalProperties: false,
          required: %w[account_id content],
          properties: {
            account_id: { type: "integer", description: "Account to draft the post under." },
            content: { type: "string", description: "Post text content." },
            scheduled_at: { type: "string", description: "Optional ISO8601 suggested time; stored on the draft for the user to confirm." }
          }
        }
      end

      def call
        account = find_user_account!(args[:account_id])
        content = args[:content].to_s
        raise InvalidParams, "content required" if content.strip.empty?

        scheduled_at = fetch_time(:scheduled_at, default: nil)

        post = account.posts.build(content: content, status: :draft, scheduled_at: scheduled_at)
        raise AppError, post.errors.full_messages.join(", ") unless post.save

        {
          ok: true,
          post: serialize_post(post),
          note: "Saved as a draft. To publish it, open Emanator and use Sign & Schedule (requires Amber)."
        }
      end
    end
  end
end
