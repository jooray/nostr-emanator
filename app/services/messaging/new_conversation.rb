# frozen_string_literal: true

module Messaging
  # Starts a private conversation: the sending account, a recipient and the first
  # message. Shared by the web "New message" page and the app
  # (Api::V1::ConversationsController#create).
  #
  # A NIP-17 room is its participant set, so writing to somebody we already talk
  # to from this account continues that room rather than opening a second one.
  # The room is only created together with its first message: an abandoned
  # "new message" must not leave an empty thread in the inbox.
  #
  # Delivery is decided in the thread exactly as for a reply. A recipient with no
  # kind 10050 still gets a best-effort NIP-17 message, and if that fails the
  # thread offers the acknowledged legacy downgrade — never this service.
  class NewConversation
    Result = Data.define(:conversation, :message, :error) do
      def ok? = error.nil?
    end

    def self.call(user, **) = new(user).call(**)

    # The recipient as typed or picked: npub, nprofile (with or without
    # `nostr:`) or 64-character hex. nil when it is none of those.
    def self.resolve_pubkey(input)
      value = input.to_s.strip.sub(/\Anostr:/i, "")
      return value.downcase if Nostr::KeyConverter.valid_hex_pubkey?(value)

      parsed = Nostr::KeyConverter.parse_nostr_identifier(value)
      pubkey = parsed&.dig(:pubkey) if parsed && %i[npub nprofile].include?(parsed[:type])
      Nostr::KeyConverter.valid_hex_pubkey?(pubkey) ? pubkey.downcase : nil
    end

    def initialize(user)
      @user = user
    end

    def call(account_id:, recipient:, content:)
      account = @user.accounts.find_by(id: account_id)
      return failure(I18n.t("messaging.errors.choose_account")) unless account
      return failure(I18n.t("messaging.errors.account_cannot_message")) unless account.messaging_capable?

      peer = self.class.resolve_pubkey(recipient)
      return failure(I18n.t("messaging.errors.no_recipient")) unless peer
      return failure(I18n.t("messaging.errors.write_first")) if content.to_s.strip.blank?

      result = nil
      Conversation.transaction do
        conversation = room_for(account, peer)
        result = OutboundBuilder.new(conversation).build(content: content)
        raise ActiveRecord::Rollback unless result.ok?

        # Writing to someone is the Known rule; unarchive a room the user had put
        # away, since they are talking there again.
        conversation.update!(archived: false, has_replied: true, last_message_at: Time.current)
        SenderClassifier.new(@user, wot: false).classify!(conversation)
      end
      return failure(result.error) unless result.ok?

      DeliveryMode.enqueue(result.message)
      Result.new(conversation: result.message.conversation, message: result.message, error: nil)
    end

    private

    def room_for(account, peer)
      participants = [ account.pubkey_hex.downcase, peer ].uniq.sort
      account.conversations.create_or_find_by!(
        protocol: "nip17",
        participants_key: Nostr::Nip17.participants_key(participants)
      ) do |room|
        room.user = @user
        room.participant_pubkeys = participants
        room.peer_pubkey = participants.size == 2 ? peer : nil
        room.classification = "known"
        room.classification_reason = peer == account.pubkey_hex.downcase ? "self" : "replied"
        room.has_replied = true
        room.last_message_at = Time.current
      end
    end

    def failure(error) = Result.new(conversation: nil, message: nil, error: error)
  end
end
