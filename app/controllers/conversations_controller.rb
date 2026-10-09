# frozen_string_literal: true

# The centralized DM inbox, spanning every paired account.
#
# Unlike InteractionsController (which reads a cache and never touches relays),
# conversations are real rows, so this is plain SQL — no relay I/O, no signer
# calls, nothing that can block the request. Fetching and decryption happen in
# PollDirectMessagesJob / DecryptGiftWrapsJob.
class ConversationsController < ApplicationController
  before_action :set_conversation, only: %i[show composer accept block mark_read]

  PER_PAGE = 30
  THREAD_LIMIT = 100

  TABS = %w[known requests].freeze

  def index
    @accounts = current_user.accounts.order(:created_at).to_a
    @tab = TABS.include?(params[:tab]) ? params[:tab] : "known"
    @account_filter = resolve_account_filter
    @messaging_accounts = @accounts.select(&:needs_messaging_repair?)

    @counts = {
      "known" => filtered(base_scope.known).count,
      "requests" => filtered(base_scope.request).count
    }
    @unread_only = params[:unread] == "1"
    scope = filtered(base_scope.public_send(@tab == "requests" ? :request : :known))
    scope = scope.with_unread if @unread_only
    @conversations = scope.recent_first.page(params[:page]).per(PER_PAGE)

    @sync_states = DmSyncState.where(account_id: @accounts.map(&:id)).index_by(&:account_id)
  end

  def show
    # Newest THREAD_LIMIT, then re-ordered oldest-first for display.
    @messages = @conversation.messages.newest_first.limit(THREAD_LIMIT).to_a.reverse
    @has_more = @conversation.messages.count > THREAD_LIMIT
    @delivery = Messaging::DeliveryMode.for(@conversation)
    mark_conversation_read
  end

  # Re-rendered by the composer's own Turbo Frame while a peer's kind 10050 is
  # still being resolved, so the user never has to reload to find out.
  def composer
    # The body only, not the frame wrapper — the caller swaps this into the frame
    # it already has, and a nested frame would break the swap.
    render partial: "conversations/composer_body",
           locals: { conversation: @conversation, delivery: Messaging::DeliveryMode.for(@conversation) },
           layout: false
  end

  def accept
    @conversation.accept!
    redirect_back fallback_location: conversation_path(@conversation), notice: t(".moved")
  end

  def block
    @conversation.block!
    redirect_to messages_path, notice: t(".blocked")
  end

  def mark_read
    mark_conversation_read
    head :no_content
  end

  # Clears every unread conversation in the tab the user is looking at, honouring
  # the account filter — "mark all as read" that silently also cleared accounts
  # they had filtered out would be a nasty surprise.
  def mark_all_read
    @accounts = current_user.accounts.order(:created_at).to_a
    @account_filter = resolve_account_filter
    tab = TABS.include?(params[:tab]) ? params[:tab] : "known"

    scope = filtered(base_scope.public_send(tab == "requests" ? :request : :known)).with_unread
    cleared = scope.count
    now = Time.current

    scope.find_each { |conversation| conversation.mark_read!(now) }
    redirect_to messages_path(tab: tab, accounts: @account_filter),
                notice: cleared.positive? ? t(".marked", count: cleared) : t(".nothing_unread")
  end

  private

  def base_scope
    current_user.conversations.active.includes(:account)
  end

  def filtered(scope)
    @account_filter.any? ? scope.where(account_id: @account_filter) : scope
  end

  def resolve_account_filter
    requested = params.key?(:accounts) ? Array(params[:accounts]) : nil
    Messaging::AccountFilter.new(current_user, @accounts).resolve(requested)
  end

  def mark_conversation_read
    @conversation.mark_read! if @conversation.unread?
  end

  # Scoped through current_user, always. A leaked DM is worse than a leaked post.
  def set_conversation
    @conversation = current_user.conversations.find(params[:id])
  end
end
