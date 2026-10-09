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
    return redirect_to conversation_path(conversation), alert: t(".cannot_retry") unless @message.can_retry?

    # Retrying a private message to somebody with no kind 10050 is guaranteed to
    # fail the same way — there is nowhere to deliver it. Point at the downgrade
    # instead of spending another round of signer calls to learn that again.
    if Messaging::DeliveryMode.undeliverable_privately?(@message)
      return redirect_to conversation_path(conversation),
                         alert: t(".no_inbox")
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
      return redirect_to conversation_path(conversation), alert: t(".cannot_downgrade")
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

  def enqueue(message) = Messaging::DeliveryMode.enqueue(message)

  # Scoped through current_user, always.
  def set_conversation
    @conversation = current_user.conversations.find(params[:conversation_id])
  end

  def set_message
    @message = Message.where(user_id: current_user.id).find(params[:id])
  end
end
