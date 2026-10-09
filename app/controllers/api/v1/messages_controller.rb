# frozen_string_literal: true

module Api
  module V1
    # Sending, retrying and the acknowledged legacy downgrade — the same rules
    # as MessagesController (the legacy acknowledgement is enforced by the
    # Message model, whatever any client sends).
    class MessagesController < BaseController
      def create
        conversation = current_user.conversations.find(params[:conversation_id])
        result = Messaging::OutboundBuilder.new(conversation).build(
          content: params[:content],
          reply_to: params[:reply_to].presence,
          legacy_ack: ActiveModel::Type::Boolean.new.cast(params[:legacy_ack])
        )
        return render_error(result.error) unless result.ok?

        Messaging::DeliveryMode.enqueue(result.message)
        # Accepting the downgrade moves the reply into the legacy thread for the
        # same peer; conversation_id tells the app to follow it there.
        render json: { message: serializer.message(result.message), conversation_id: result.message.conversation_id }, status: :created
      end

      def show
        render json: { message: serializer.message(find_message) }
      end

      def retry
        message = find_message
        return render_error(I18n.t("messages.retry.cannot_retry")) unless message.can_retry?
        # Retrying a private message to somebody with no kind 10050 is guaranteed
        # to fail the same way — point at the downgrade instead.
        return render_error(I18n.t("messages.retry.no_inbox"), code: "no_inbox") if Messaging::DeliveryMode.undeliverable_privately?(message)

        message.update!(status: "pending", error: nil)
        Messaging::DeliveryMode.enqueue(message)
        render json: { message: serializer.message(message) }
      end

      # Resend a failed private message as an acknowledged legacy one. The
      # original is replaced, as on the web.
      def downgrade
        message = find_message
        unless message.can_retry? && message.kind != Message::LEGACY_KIND
          return render_error(I18n.t("messages.downgrade.cannot_downgrade"))
        end
        unless ActiveModel::Type::Boolean.new.cast(params[:legacy_ack])
          return render_error(I18n.t("messaging.errors.legacy_unacknowledged"), code: "ack_required")
        end

        result = Messaging::OutboundBuilder.new(message.conversation).build(content: message.content, legacy_ack: true)
        return render_error(result.error) unless result.ok?

        message.destroy!
        Messaging::DeliveryMode.enqueue(result.message)
        render json: { message: serializer.message(result.message), conversation_id: result.message.conversation_id }
      end

      private

      def find_message
        Message.where(user_id: current_user.id).find(params[:id])
      end
    end
  end
end
