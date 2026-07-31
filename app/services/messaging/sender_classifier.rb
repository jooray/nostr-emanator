# frozen_string_literal: true

module Messaging
  # Decides whether a conversation belongs in the main inbox ("known") or behind
  # the Requests tab.
  #
  # Gift wraps are signed by a throwaway key, so nothing can be filtered before
  # decryption — every rule here runs on the sender recovered from the *seal*,
  # after we have already paid to unwrap.
  #
  # Rules are evaluated in strict cost order, and every rule except the WoT hop is
  # a cache or column read. Only a genuine stranger ever reaches the network.
  class SenderClassifier
    # Positive answers are stable; negative ones should re-check sooner, because a
    # follow that appears later should promote the conversation reasonably fast.
    WOT_POSITIVE_TTL = 7.days
    WOT_NEGATIVE_TTL = 24.hours
    # A relay filter with an unbounded `authors` array gets rejected; this also
    # bounds how much of a large follow list we ask about.
    WOT_AUTHOR_LIMIT = 500

    Result = Data.define(:classification, :reason)

    def initialize(user, wot: true)
      @user = user
      @wot = wot
      @muted = InteractionsCache.read_muted_pubkeys(user)
      @own_pubkeys = user.accounts.pluck(:pubkey_hex).map(&:downcase).to_set
      @own_pubkeys << user.pubkey_hex.to_s.downcase
    end

    def classify(conversation)
      sender = conversation.participant_pubkeys.find { |pk| !own?(pk) }

      # No third party in the room: a note-to-self thread is always ours.
      return Result.new(classification: "known", reason: "self") if sender.nil?
      return Result.new(classification: "muted", reason: "manual") if @muted.include?(sender)
      return Result.new(classification: "known", reason: "self") if own?(sender)

      # We have written in this thread, so we have already vouched for it.
      return Result.new(classification: "known", reason: "replied") if conversation.has_replied?

      return Result.new(classification: "known", reason: "own_follow") if follows?(conversation.account, sender)
      return Result.new(classification: "known", reason: "sibling_follow") if any_sibling_follows?(sender)
      return Result.new(classification: "known", reason: "wot") if @wot && wot_vouches_for?(sender)

      Result.new(classification: "request", reason: "unclassified")
    end

    # Applies the result, respecting a manual Accept/Block.
    def classify!(conversation)
      return false if conversation.classification_locked?

      result = classify(conversation)
      conversation.classify!(result.classification, result.reason)
    end

    private

    def own?(pubkey) = @own_pubkeys.include?(pubkey.to_s.downcase)

    def follows?(account, sender)
      contact_list(account.pubkey_hex).include?(sender)
    end

    # The user's *other* accounts vouching for a sender counts too.
    #
    # Rationale from the product owner: people typically have one main account
    # that does the following, and manage several others from it. A sender that
    # main account follows is trustworthy enough to show under the others, rather
    # than making the user accept the same person once per identity.
    def any_sibling_follows?(sender)
      sibling_follows.include?(sender)
    end

    def sibling_follows
      @sibling_follows ||= Rails.cache.fetch("dm_sibling_follows_user_#{@user.id}", expires_in: 5.minutes) do
        pubkeys = @user.accounts.pluck(:pubkey_hex) + [ @user.pubkey_hex ]
        pubkeys.compact.uniq.reduce(Set.new) { |set, pubkey| set | contact_list(pubkey) }
      end
    end

    def contact_list(pubkey)
      return Set.new if pubkey.blank?

      (@contact_lists ||= {})[pubkey] ||= InteractionsCache.read_contact_list(pubkey)
    end

    # "Do any of the people we follow, follow this sender?" — one relay query, not
    # a materialised graph. A follows-of-follows table would be ~10^5 rows and a
    # refresh problem to answer a boolean.
    def wot_vouches_for?(sender)
      cached = Rails.cache.read(wot_key(sender))
      return cached unless cached.nil?

      unless wot_budget_available?
        # Fail safe: an unclassified stranger waits in Requests. The degradation
        # is "a legitimate person waits", never "spam reaches the main inbox".
        Rails.logger.info("WoT budget exhausted for user #{@user.id}; leaving sender in Requests")
        return false
      end

      vouched = query_wot(sender)
      Rails.cache.write(wot_key(sender), vouched, expires_in: vouched ? WOT_POSITIVE_TTL : WOT_NEGATIVE_TTL)
      vouched
    end

    def query_wot(sender)
      pool = follow_pool
      return false if pool.empty?

      events = Nostr::EventFetcher.new.fetch_contact_lists_mentioning(sender, authors: pool)
      events.any?
    rescue StandardError => e
      Rails.logger.warn("WoT lookup failed for #{sender.inspect}: #{e.message}")
      false
    end

    # Deterministically ordered so the truncation is stable and therefore
    # cacheable: the login identity's follows first, then accounts by age.
    def follow_pool
      @follow_pool ||= begin
        ordered = [ @user.pubkey_hex ] + @user.accounts.order(:created_at).pluck(:pubkey_hex)
        ordered.compact.uniq.reduce([]) { |list, pubkey| list | contact_list(pubkey).to_a }
          .first(WOT_AUTHOR_LIMIT)
      end
    end

    def wot_key(sender) = "dm_wot_user_#{@user.id}_#{sender}"

    def wot_budget_available?
      limit = Rails.application.config_for(:emanator).dig(:messaging, :wot_lookups_per_hour) || 50
      key = "dm_wot_budget_user_#{@user.id}_#{Time.current.strftime('%Y%m%d%H')}"
      used = Rails.cache.increment(key, 1, expires_in: 1.hour, initial: 0) || 1
      used <= limit
    end
  end
end
