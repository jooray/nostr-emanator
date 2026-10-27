# frozen_string_literal: true

module Mentions
  # The composer's @mention lookup, shared by the web (MentionsController) and
  # the app (Api::V1::MentionsController). The user's own accounts come first,
  # then people any of those accounts follow, from NostrProfile. Picking one
  # inserts `nostr:npub…`, which Nostr::ContentTagger turns into a `p` tag.
  #
  # The new-message recipient picker runs the same lookup with `peers: true`,
  # which also offers people the user already has conversations with. A pasted
  # npub, nprofile or hex key always resolves to exactly that person.
  class Search
    LIMIT = 8
    CANDIDATES = 200

    Result = Data.define(:pubkey_hex, :npub, :name, :display_name, :nip05, :picture_url, :own, :account_id)

    def self.call(user, query, limit: LIMIT, peers: false) = new(user, query, limit:, peers:).results

    def initialize(user, query, limit: LIMIT, peers: false)
      @user = user
      @raw = query.to_s.strip.delete_prefix("@")
      @query = @raw.downcase.first(64)
      @limit = limit
      @peers = peers
    end

    def results
      if (pubkey = identifier_pubkey)
        return [ direct(pubkey) ]
      end

      own = own_accounts
      (own + followed(exclude: own.map(&:pubkey_hex))).first(@limit)
    end

    private

    def accounts = @accounts ||= @user.accounts.order(:created_at).to_a

    def own_accounts
      accounts.select { |a| matches?([ a.display_name, a.username ]) || npub_match?(a.npub) }
              .sort_by { |a| [ rank([ a.display_name, a.username ]), a.created_at ] }
              .map do |a|
        Result.new(pubkey_hex: a.pubkey_hex, npub: a.npub, name: a.username, display_name: a.display_name,
                   nip05: nil, picture_url: a.picture_url, own: true, account_id: a.id)
      end
    end

    # People followed by more of the user's accounts rank higher: that is the
    # "main account follows them" signal the DM classifier also relies on.
    def followed(exclude:)
      return [] if @query.empty?

      counts = Hash.new(0)
      accounts.each { |a| InteractionsCache.read_contact_list(a.pubkey_hex).each { |pk| counts[pk] += 1 } }
      conversation_peers.each { |pk| counts[pk] += 1 } if @peers
      exclude.each { |pk| counts.delete(pk) }
      return [] if counts.empty?

      pattern = "%#{NostrProfile.sanitize_sql_like(@query)}%"
      NostrProfile.where(pubkey_hex: counts.keys)
                  .where("LOWER(name) LIKE :p OR LOWER(display_name) LIKE :p OR LOWER(nip05) LIKE :p", p: pattern)
                  .limit(CANDIDATES).to_a
                  .sort_by { |p| [ rank([ p.display_name, p.name, p.nip05 ]), -counts[p.pubkey_hex], p.label.downcase ] }
                  .first(@limit)
                  .map do |p|
        Result.new(pubkey_hex: p.pubkey_hex, npub: p.npub, name: p.name, display_name: p.display_name,
                   nip05: p.nip05, picture_url: p.picture_url, own: false, account_id: nil)
      end
    end

    def conversation_peers
      @user.conversations.where.not(peer_pubkey: nil).where.not(classification: "muted")
           .distinct.pluck(:peer_pubkey)
    end

    def identifier_pubkey
      return nil unless @raw.match?(/\A(?:nostr:)?(?:npub1|nprofile1)|\A\h{64}\z/i)

      Messaging::NewConversation.resolve_pubkey(@raw)
    end

    # Whoever the key belongs to, profile known or not: the user pasted it.
    def direct(pubkey)
      account = accounts.find { |a| a.pubkey_hex.casecmp?(pubkey) }
      if account
        return Result.new(pubkey_hex: account.pubkey_hex, npub: account.npub, name: account.username,
                          display_name: account.display_name, nip05: nil, picture_url: account.picture_url,
                          own: true, account_id: account.id)
      end

      profile = NostrProfile.find_by(pubkey_hex: pubkey)
      Result.new(pubkey_hex: pubkey, npub: Nostr::KeyConverter.hex_to_npub(pubkey), name: profile&.name,
                 display_name: profile&.display_name, nip05: profile&.nip05, picture_url: profile&.picture_url,
                 own: false, account_id: nil)
    end

    # Letters of a bech32 npub are noise to a name search ("nal" occurs in plenty
    # of them), so an npub only matches a query that is itself an npub prefix.
    def npub_match?(npub) = @query.start_with?("npub1") && npub.to_s.start_with?(@query)

    def matches?(fields)
      @query.empty? || fields.compact.any? { |f| f.downcase.include?(@query) }
    end

    # 0: a field starts with the query, 1: a word in it does, 2: it only contains it.
    def rank(fields)
      values = fields.compact.map(&:downcase)
      return 0 if values.any? { |v| v.start_with?(@query) }
      return 1 if values.any? { |v| v.split(/[\s._@-]+/).any? { |w| w.start_with?(@query) } }
      2
    end
  end
end
