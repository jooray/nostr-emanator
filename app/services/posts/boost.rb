# frozen_string_literal: true

module Posts
  # "Boost as…": another of the user's accounts reposts (kind 6) a note that is
  # already out, signed and published at once. It is an ordinary Repost row, so
  # the note's page, the lists and the retry/rebroadcast paths all treat it like
  # a scheduled repost that happened to be due now. Web, API and app share it.
  class Boost
    Result = Struct.new(:ok, :error, :repost, keyword_init: true)

    # A repost in one of these states is already going out (or went out);
    # boosting again would only collide with it. A failed one may be redone.
    IN_FLIGHT = %w[pending_signature awaiting_signature scheduled publishing published].freeze

    def self.boostable?(post)
      post.is_a?(Post) && post.published? && post.signed_event.present?
    end

    # The accounts that can boost `post`: the user's others, with a signer, that
    # have not already reposted it. `accounts` lets a list pass the set it has
    # loaded already, so a page of rows costs no extra queries.
    def self.candidates(post, accounts = post.account.user.accounts)
      return [] unless boostable?(post)

      taken = post.reposts.select { |r| IN_FLIGHT.include?(r.status) }.map(&:account_id)
      accounts.select { |a| a.id != post.account_id && a.has_signer? && !taken.include?(a.id) }
    end

    def initialize(post, account)
      @post = post
      @account = account
    end

    def call
      return failure("posts.boost.not_published") unless self.class.boostable?(@post)
      return failure("posts.boost.own_note") if @account.id == @post.account_id
      return failure("posts.boost.no_signer", name: @account.display_name_or_npub) unless @account.has_signer?

      repost = @post.reposts.find_or_initialize_by(account: @account)
      return failure("posts.boost.already", name: @account.display_name_or_npub) if repost.persisted? && IN_FLIGHT.include?(repost.status)

      now = Time.current
      unsigned = Nostr::EventSignerService.new.build_unsigned_repost(
        original_event: @post.signed_event, pubkey: @account.pubkey_hex, created_at: now
      )
      repost.update!(unsigned_event: unsigned, signed_event: nil, event_id: nil, publish_results: nil,
                     published_at: nil, scheduled_at: now, delay_minutes: 0, status: :awaiting_signature)
      PublishNowRepostJob.perform_later(repost.id)

      Result.new(ok: true, repost: repost)
    end

    private

    def failure(key, **args)
      Result.new(ok: false, error: I18n.t(key, **args))
    end
  end
end
