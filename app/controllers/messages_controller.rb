# frozen_string_literal: true

class MessagesController < ApplicationController
  before_action :set_conversation, only: :create
  before_action :set_message, only: %i[retry downgrade]

  def create
    result = Messaging::OutboundBuilder.new(@conversation).build(
      content: params[:content],
      reply_to: params[:reply_to].presence,
      legacy_ack: params[:legacy_ack] == "1"
    )

    if result.ok?
      enqueue(result.message)
      # Accepting the downgrade moves the reply into the legacy thread for the
      # same peer, so follow it there rather than leaving the user looking at a
      # room their message is not in.
      redirect_to conversation_path(result.message.conversation)
    else
      redirect_to conversation_path(@conversation), alert: result.error
    end
  end

  def retry
    conversation = @message.conversation
    return redirect_to conversation_path(conversation), alert: "That message cannot be retried." unless @message.can_retry?

    # Retrying a private message to somebody with no kind 10050 is guaranteed to
    # fail the same way — there is nowhere to deliver it. Point at the downgrade
    # instead of spending another round of signer calls to learn that again.
    if undeliverable_privately?(@message)
      return redirect_to conversation_path(conversation),
                         alert: "This person still has no DM inbox, so a private message cannot reach them. " \
                                "You can send it as a legacy message instead."
    end

    @message.update!(status: "pending", error: nil)
    enqueue(@message)
    redirect_to conversation_path(conversation)
  end

  # Resend a failed private message as an acknowledged legacy one.
  #
  # The original is destroyed rather than kept: it was never delivered, and the
  # user is explicitly replacing it — leaving a permanent "Failed to send" next to
  # the copy that did go out is just noise.
  def downgrade
    conversation = @message.conversation
    unless @message.can_retry? && @message.kind != Message::LEGACY_KIND
      return redirect_to conversation_path(conversation), alert: "That message cannot be downgraded."
    end

    result = Messaging::OutboundBuilder.new(conversation).build(content: @message.content, legacy_ack: true)

    if result.ok?
      @message.destroy!
      enqueue(result.message)
      redirect_to conversation_path(result.message.conversation)
    else
      redirect_to conversation_path(conversation), alert: result.error
    end
  end

  private

  # True when a private retry cannot possibly work: the peer has published no
  # kind 10050, so there is no relay a gift wrap could be delivered to.
  def undeliverable_privately?(message)
    return false if message.kind == Message::LEGACY_KIND

    peer = message.conversation.peer_pubkeys.first
    return false if peer.blank?

    list = Nostr::DmRelayListService.new.cached(peer)
    list.present? && !list.deliverable?
  end

  def enqueue(message)
    if message.legacy_downgrade?
      SendLegacyDirectMessageJob.perform_later(message.id)
    else
      SendDirectMessageJob.perform_later(message.id)
    end
  end

  # Scoped through current_user, always.
  def set_conversation
    @conversation = current_user.conversations.find(params[:conversation_id])
  end

  def set_message
    @message = Message.where(user_id: current_user.id).find(params[:id])
  end
end
