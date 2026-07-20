# frozen_string_literal: true

module Mcp
  module Tools
    class ListAccounts < Base
      def self.description
        <<~DESC.strip
          List all Nostr accounts the authenticated user manages, with the metadata
          that says who posts what: each account's npub, display name, personality
          style guide (used for AI post writing), write relays, whether it has a
          paired signer, and counts of total / upcoming (scheduled) / published /
          draft posts. Call this first to learn which accounts exist and their ids.
        DESC
      end

      def self.input_schema
        { type: "object", properties: {}, additionalProperties: false }
      end

      def call
        accounts = user.accounts.order(:username).to_a
        ids = accounts.map(&:id)

        totals = Post.where(account_id: ids).group(:account_id).count
        published = Post.where(account_id: ids, status: :published).group(:account_id).count
        drafts = Post.where(account_id: ids, status: :draft).group(:account_id).count
        upcoming = Post.where(account_id: ids, status: [:scheduled, :awaiting_signature])
          .where("scheduled_at > ?", Time.current)
          .group(:account_id).count

        result = accounts.map do |a|
          serialize_account(a, counts: {
            total: totals[a.id] || 0,
            upcoming: upcoming[a.id] || 0,
            published: published[a.id] || 0,
            draft: drafts[a.id] || 0
          })
        end

        { accounts: result }
      end
    end
  end
end
