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
    @delivery = delivery_mode
    mark_conversation_read
  end

  # Re-rendered by the composer's own Turbo Frame while a peer's kind 10050 is
  # still being resolved, so the user never has to reload to find out.
  def composer
    # The body only, not the frame wrapper — the caller swaps this into the frame
    # it already has, and a nested frame would break the swap.
    render partial: "conversations/composer_body",
           locals: { conversation: @conversation, delivery: delivery_mode },
           layout: false
  end

  def accept
    @conversation.accept!
    redirect_back fallback_location: conversation_path(@conversation), notice: "Moved to your inbox."
  end

  def block
    @conversation.block!
    redirect_to messages_path, notice: "Blocked. You will not see messages from this conversation."
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

    scope.find_each do |conversation|
      conversation.update!(unread_count: 0, last_read_at: now)
      record_read_state(conversation, now)
    end

    Rails.cache.delete(MessagesHelper.unread_cache_key(current_user))
    redirect_to messages_path(tab: tab, accounts: @account_filter),
                notice: cleared.positive? ? "Marked #{cleared} conversation#{"s" if cleared != 1} as read." : "Nothing unread."
  end

  private

  # How (and whether) a reply in this thread can be delivered. Cache reads only —
  # never relay I/O in a request.
  #
  #   :self          note-to-self, nothing to resolve
  #   :legacy        already a kind-4 thread; replies stay legacy
  #   :nip17         the peer published a DM inbox, so private messaging works
  #   :unavailable   the peer has no signer permissions on our side
  #   :best_effort   no kind 10050. We still send — to their NIP-65 read relays,
  #                  or popular relays — but say so, and keep the legacy option
  #                  visible for recipients whose client has no NIP-17 at all.
  #   :checking      we have not resolved their 10050 yet; refreshing in the
  #                  background. Deliberately distinct, so a cold cache never
  #                  makes a normal conversation look degraded.
  def delivery_mode
    return :unavailable unless @conversation.account.messaging_capable?

    peer = @conversation.peer_pubkeys.first
    return :self if peer.blank?
    return :legacy if @conversation.legacy?

    list = Nostr::DmRelayListService.new.cached(peer)

    if list.nil? || list.stale?
      RefreshDmRelayListJob.perform_later(peer)
      return list&.deliverable? ? :nip17 : :checking
    end

    list.deliverable? ? :nip17 : :best_effort
  end

  def base_scope
    current_user.conversations.active.includes(:account)
  end

  def filtered(scope)
    @account_filter.any? ? scope.where(account_id: @account_filter) : scope
  end

  # Server-side, not the client-side pill filter the interactions page uses:
  # hiding rows in the DOM interacts badly with pagination (short and empty
  # pages). Persisted so the choice survives navigation.
  def resolve_account_filter
    if params.key?(:accounts)
      ids = normalize_filter(Array(params[:accounts]).map(&:to_i))
      persist_account_filter(ids)
      return ids
    end

    normalize_filter(Array(current_user.settings&.dig("dm_account_filter")).map(&:to_i))
  end

  # Empty is the canonical "every account". Selecting all of them by hand must
  # collapse to the same thing, or the UI would show a "Select all" link next to
  # a set that is already all of them.
  def normalize_filter(ids)
    ids &= @accounts.map(&:id)
    ids.sort == @accounts.map(&:id).sort ? [] : ids
  end

  def persist_account_filter(ids)
    settings = (current_user.settings || {}).merge("dm_account_filter" => ids)
    current_user.update_column(:settings, settings)
  end

  def mark_conversation_read
    return unless @conversation.unread?

    read_at = Time.current
    @conversation.update!(unread_count: 0, last_read_at: read_at)
    Rails.cache.delete(MessagesHelper.unread_cache_key(current_user))

    record_read_state(@conversation, read_at)
  end

  # Local DB is the source of truth for the UI; NIP-RS is best-effort sync, so a
  # failure here must never break opening a thread.
  def record_read_state(conversation, read_at)
    Messaging::ReadStateService.new(conversation.account).mark_read(conversation, read_at)
  rescue StandardError => e
    Rails.logger.warn("Could not record read state: #{e.message}")
  end

  # Scoped through current_user, always. A leaked DM is worse than a leaked post.
  def set_conversation
    @conversation = current_user.conversations.find(params[:id])
  end
end
