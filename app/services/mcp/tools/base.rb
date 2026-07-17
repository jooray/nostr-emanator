# frozen_string_literal: true

module Mcp
  module Tools
    # Base class for MCP tools. Each tool is scoped to a single authenticated
    # user and may only read/write that user's accounts, posts and reposts.
    class Base
      class InvalidParams < StandardError; end
      class AppError < StandardError; end

      MAX_LIMIT = 200

      def initialize(user, args)
        @user = user
        @args = (args || {}).with_indifferent_access
      end

      def self.description
        raise NotImplementedError
      end

      def self.input_schema
        raise NotImplementedError
      end

      def call
        raise NotImplementedError
      end

      private

      attr_reader :user, :args

      def fetch_int(key, default:, min: 0, max: MAX_LIMIT)
        v = args[key]
        return default if v.nil? || v == ""
        i = Integer(v)
        i.clamp(min, max)
      rescue ArgumentError, TypeError
        raise InvalidParams, "#{key} must be an integer"
      end

      def fetch_bool(key, default:)
        v = args[key]
        return default if v.nil?
        ActiveModel::Type::Boolean.new.cast(v)
      end

      def fetch_time(key, default:)
        v = args[key]
        return default if v.blank?
        Time.iso8601(v.to_s)
      rescue ArgumentError
        raise InvalidParams, "#{key} must be an ISO8601 timestamp"
      end

      # Scope of every post belonging to the authenticated user.
      def user_posts
        Post.joins(:account).where(accounts: { user_id: user.id })
      end

      def find_user_account!(account_id)
        raise InvalidParams, "account_id required" if account_id.blank?
        user.accounts.find_by!(id: account_id)
      end

      def find_user_post!(post_id)
        raise InvalidParams, "post_id required" if post_id.blank?
        user_posts.find_by!(id: post_id)
      end

      def serialize_account(account, counts: nil)
        {
          id: account.id,
          npub: account.npub,
          pubkey_hex: account.pubkey_hex,
          username: account.username,
          display_name: account.display_name,
          about: account.about,
          personality: account.personality,
          write_relays: account.write_relays,
          has_signer: account.has_signer?,
          signer_relay: account.signer_relay,
          total_posts: counts&.dig(:total),
          upcoming_posts: counts&.dig(:upcoming),
          published_posts: counts&.dig(:published),
          draft_posts: counts&.dig(:draft)
        }.compact
      end

      def serialize_post(post, include_reposts: true)
        {
          id: post.id,
          account_id: post.account_id,
          account_name: post.account.display_name_or_npub,
          status: post.status,
          content: post.content,
          event_kind: post.event_kind,
          is_reply: post.is_reply,
          event_id: post.event_id,
          signed: post.signed_event.present?,
          scheduled_at: post.scheduled_at&.iso8601,
          published_at: post.published_at&.iso8601,
          created_at: post.created_at&.iso8601,
          reposts: include_reposts ? post.reposts.map { |r| serialize_repost(r) } : nil
        }.compact
      end

      def serialize_repost(repost)
        {
          id: repost.id,
          account_id: repost.account_id,
          account_name: repost.account.display_name_or_npub,
          status: repost.status,
          delay_minutes: repost.delay_minutes,
          scheduled_at: repost.scheduled_at&.iso8601,
          published_at: repost.published_at&.iso8601
        }.compact
      end
    end
  end
end
