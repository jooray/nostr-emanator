# frozen_string_literal: true

module Api
  module V1
    # The one DM inbox across every paired account. Plain SQL over rows the
    # background pipeline already decrypted — no relay or signer call in a
    # request, same as ConversationsController.
    class ConversationsController < BaseController
      PER_PAGE = ::ConversationsController::PER_PAGE
      THREAD_LIMIT = ::ConversationsController::THREAD_LIMIT
      TABS = ::ConversationsController::TABS

      before_action :set_conversation, only: %i[show accept block mark_read]

      def index
        accounts = current_user.accounts.order(:created_at).to_a
        tab = TABS.include?(params[:tab]) ? params[:tab] : "known"
        account_filter = Messaging::AccountFilter.new(current_user, accounts)
                                                 .resolve(params.key?(:account_ids) ? Array(params[:account_ids]) : nil)
        base = current_user.conversations.active.includes(:account)
        base = base.where(account_id: account_filter) if account_filter.any?

        scope = base.public_send(tab == "requests" ? :request : :known)
        scope = scope.with_unread if params[:unread] == "1"
        page = scope.recent_first.page(page_param).per(PER_PAGE)
        sync = DmSyncState.where(account_id: accounts.map(&:id)).index_by(&:account_id)

        render json: {
          tab: tab,
          account_filter: account_filter,
          counts: { known: base.known.count, requests: base.request.count },
          conversations: page.map { |c| serializer.conversation(c) },
          pagination: pagination(page),
          accounts_needing_repair: accounts.select(&:needs_messaging_repair?).map { |a| serializer.account_mini(a) },
          accounts_relay_auth_blocked: accounts.select(&:relay_auth_blocked?).map do |a|
            serializer.account_mini(a).merge(relay: a.settings&.dig("amber_auth_blocked_relay"))
          end,
          sync: accounts.select(&:messaging_capable?).map do |a|
            state = sync[a.id]
            { account_id: a.id, status: state&.status || "idle", step: state&.step,
              last_synced_at: serializer.time(state&.last_synced_at), pending_wraps: state&.pending_wraps.to_i }
          end
        }
      end

      # Newest THREAD_LIMIT messages oldest-first; `before` (a message id) pages
      # further back. Opening the thread marks it read, like the web.
      def show
        scope = @conversation.messages
        scope = scope.where(Message.arel_table[:sort_at].lt(Message.find_by(id: params[:before], conversation_id: @conversation.id)&.sort_at || Time.current + 1.year)) if params[:before].present?
        messages = scope.newest_first.limit(THREAD_LIMIT + 1).to_a
        has_more = messages.size > THREAD_LIMIT
        messages = messages.first(THREAD_LIMIT).reverse

        @conversation.mark_read! if @conversation.unread? && params[:before].blank?

        render json: {
          conversation: serializer.conversation(@conversation),
          messages: messages.map { |m| serializer.message(m) },
          has_more: has_more,
          delivery: Messaging::DeliveryMode.for(@conversation).to_s,
          legacy_downgrade_risks: Message.legacy_downgrade_risks
        }
      end

      # Starts a conversation (or continues the room this account already has
      # with that person): account_id, recipient (npub / nprofile / hex), content.
      def create
        result = Messaging::NewConversation.call(
          current_user, account_id: params[:account_id], recipient: params[:recipient], content: params[:content]
        )
        return render_error(result.error) unless result.ok?

        render json: { conversation: serializer.conversation(result.conversation), message: serializer.message(result.message) },
               status: :created
      end

      def accept
        @conversation.accept!
        render json: { conversation: serializer.conversation(@conversation), message: I18n.t("conversations.accept.moved") }
      end

      def block
        @conversation.block!
        render json: { conversation: serializer.conversation(@conversation), message: I18n.t("conversations.block.blocked") }
      end

      def mark_read
        @conversation.mark_read! if @conversation.unread?
        head :no_content
      end

      # Honours the saved account filter, like the web — clearing accounts the
      # user had filtered out would be a nasty surprise.
      def mark_all_read
        accounts = current_user.accounts.to_a
        filter = Messaging::AccountFilter.new(current_user, accounts).resolve(nil)
        tab = TABS.include?(params[:tab]) ? params[:tab] : "known"
        scope = current_user.conversations.active.public_send(tab == "requests" ? :request : :known).with_unread
        scope = scope.where(account_id: filter) if filter.any?

        cleared = scope.count
        now = Time.current
        scope.find_each { |conversation| conversation.mark_read!(now) }
        render json: { cleared: cleared }
      end

      private

      # Scoped through current_user, always. A leaked DM is worse than a leaked post.
      def set_conversation
        @conversation = current_user.conversations.find(params[:id])
      end
    end
  end
end
