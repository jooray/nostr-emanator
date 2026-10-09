# frozen_string_literal: true

module Posts
  # Sign & schedule a draft: set the time, build the unsigned note, add the
  # reposts, and hand everything to SignPostJob.
  #
  # One implementation for every surface that schedules — the web schedule form,
  # the native app's API and the MCP `schedule_post` tool. They used to be three
  # copies and had already drifted: the MCP copy silently skipped a repost whose
  # account had no signer, where the web marked it failed so the user could see it.
  class Scheduler
    Result = Struct.new(:ok, :error, :reposts_scheduled, :reposts_skipped, keyword_init: true) do
      def ok? = ok
    end

    REPOSTS = Scheduling::RepostSchedulerService

    def initialize(post)
      @post = post
    end

    # scheduled_at must already be a Time (see .parse_time). Returns a Result;
    # never raises for a user mistake.
    def schedule(scheduled_at:, repost_account_ids: [], max_delay_hours: nil)
      return failure(I18n.t("posts.flash.cannot_schedule")) unless post.can_schedule?
      unless post.account.has_signer?
        return failure(I18n.t("posts.flash.post_no_signer_pair_first", name: post.account.display_name_or_npub))
      end
      return failure(I18n.t("posts.flash.pick_date_time")) if scheduled_at.nil?
      return failure(I18n.t("posts.flash.time_in_past")) if scheduled_at <= Time.current

      # I6/L11: keep the repost delay window sane (1 hour .. 1 year).
      max_delay_hours = (max_delay_hours.presence || REPOSTS::DEFAULT_MAX_DELAY_HOURS).to_i
                          .clamp(1, REPOSTS::MAX_DELAY_HOURS)

      post.update!(scheduled_at: scheduled_at)

      # build_unsigned_note (not build_unsigned_event) so mentions and quoted
      # notes in the text become p/q tags — see Nostr::ContentTagger.
      unsigned = signer.build_unsigned_note(
        content: post.content,
        kind: post.event_kind,
        pubkey: post.account.pubkey_hex,
        created_at: post.scheduled_at,
        # Scheduling is user-initiated and happens once; if a quoted note's author
        # is not already cached this is the last chance to look it up.
        allow_fetch: true
      )
      post.update!(unsigned_event: unsigned, status: :awaiting_signature)

      # The repost service keeps only the user's own accounts, never this one.
      ids = Array(repost_account_ids).map(&:to_i).reject(&:zero?)
      REPOSTS.new.schedule_reposts(post, ids, max_delay_hours: max_delay_hours) if ids.any?
      prepare_reposts(unsigned)

      SignPostJob.perform_later(post.id)

      Result.new(ok: true,
                 reposts_scheduled: post.reposts.awaiting_signature.count,
                 reposts_skipped: post.reposts.failed.count)
    end

    # "2026-10-09T14:30" in the user's zone, or a full ISO8601 instant. nil when
    # blank or unreadable — the caller turns that into its own message.
    def self.parse_time(value, timezone)
      return nil if value.blank?

      tz = ActiveSupport::TimeZone[timezone.to_s] || Time.zone
      tz.parse(value.to_s)
    rescue ArgumentError, TypeError
      nil
    end

    private

    attr_reader :post

    def signer
      @signer ||= Nostr::EventSignerService.new
    end

    def prepare_reposts(unsigned)
      post.reposts.pending_signature.each do |repost|
        # H15: a repost account with no signer can never be signed — fail it now
        # rather than stranding it in awaiting_signature.
        unless repost.account.has_signer?
          repost.update!(status: :failed, publish_results: { "error" => I18n.t("posts.flash.no_signer_for_account") })
          next
        end

        unsigned_repost = signer.build_unsigned_repost(
          original_event: unsigned,
          pubkey: repost.account.pubkey_hex,
          created_at: repost.scheduled_at || Time.current
        )
        repost.update!(unsigned_event: unsigned_repost, status: :awaiting_signature)
      end
    end

    def failure(message)
      Result.new(ok: false, error: message, reposts_scheduled: 0, reposts_skipped: 0)
    end
  end
end
