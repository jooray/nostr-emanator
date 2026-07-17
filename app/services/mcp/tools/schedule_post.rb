# frozen_string_literal: true

module Mcp
  module Tools
    # Sign and schedule an existing draft. Mirrors PostsController#sign:
    # build the unsigned event, set the time, optionally add reposts, and
    # enqueue SignPostJob. Amber signs kind-1 notes without manual approval,
    # so the post moves draft -> awaiting_signature -> scheduled on its own and
    # is published at scheduled_at by the periodic publish job.
    class SchedulePost < Base
      DEFAULT_MAX_DELAY_HOURS = 24

      def self.description
        <<~DESC.strip
          Sign and schedule an existing draft post so it publishes automatically.
          Builds the Nostr event and enqueues background signing via the account's
          paired Amber signer (kind-1 notes are signed without manual confirmation),
          then the post publishes at its scheduled time. Provide scheduled_at as an
          ISO8601 time in the future; if omitted, the next free slot is chosen.
          Optionally cross-post by passing repost_account_ids — other accounts you
          manage will repost at a random delay. The account must have a paired signer.
        DESC
      end

      def self.input_schema
        {
          type: "object",
          additionalProperties: false,
          required: ["post_id"],
          properties: {
            post_id: { type: "integer", description: "Id of a draft (or awaiting_signature) post you manage." },
            scheduled_at: { type: "string", description: "ISO8601 time in the future. Default: next free slot for the account." },
            repost_account_ids: {
              type: "array",
              items: { type: "integer" },
              description: "Other accounts you manage that should repost this, each at a random delay."
            },
            max_delay_hours: { type: "integer", minimum: 1, description: "Upper bound on repost delay. Default 24." }
          }
        }
      end

      def call
        post = find_user_post!(args[:post_id])
        raise AppError, "post is #{post.status}; only drafts can be scheduled" unless post.can_schedule?

        account = post.account
        unless account.has_signer?
          raise AppError, "account '#{account.display_name_or_npub}' has no paired Amber signer; cannot sign automatically"
        end

        scheduled_at = resolve_scheduled_at(account)
        post.update!(scheduled_at: scheduled_at)

        signer = Nostr::EventSignerService.new
        unsigned = signer.build_unsigned_event(
          content: post.content,
          kind: post.event_kind,
          pubkey: account.pubkey_hex,
          created_at: post.scheduled_at
        )
        post.update!(unsigned_event: unsigned, status: :awaiting_signature)

        schedule_reposts(post, signer, unsigned)

        SignPostJob.perform_later(post.id)

        {
          ok: true,
          post: serialize_post(post.reload),
          note: "Signing enqueued. Amber signs kind-1 notes automatically, so the post moves to 'scheduled' and publishes at scheduled_at without further action."
        }
      end

      private

      def resolve_scheduled_at(account)
        provided = fetch_time(:scheduled_at, default: nil)
        if provided
          raise InvalidParams, "scheduled_at must be in the future" if provided <= Time.current
          return provided
        end

        Scheduling::SchedulerService.new(timezone: user.timezone).suggest_next_slot(account)
      end

      def schedule_reposts(post, signer, unsigned)
        repost_account_ids = Array(args[:repost_account_ids]).map(&:to_i).reject(&:zero?)
        return if repost_account_ids.empty?

        max_delay_hours = fetch_int(:max_delay_hours, default: DEFAULT_MAX_DELAY_HOURS, min: 1, max: 8_760)
        Scheduling::RepostSchedulerService.new.schedule_reposts(post, repost_account_ids, max_delay_hours: max_delay_hours)

        post.reposts.pending_signature.each do |repost|
          next unless repost.account.has_signer?

          unsigned_repost = signer.build_unsigned_repost(
            original_event: unsigned,
            pubkey: repost.account.pubkey_hex,
            created_at: repost.scheduled_at || Time.current
          )
          repost.update!(unsigned_event: unsigned_repost, status: :awaiting_signature)
        end
      end
    end
  end
end
