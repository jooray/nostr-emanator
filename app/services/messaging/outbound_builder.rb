# frozen_string_literal: true

module Messaging
  # Creates the outbound Message row for a conversation.
  #
  # The rumor is built here rather than in the send job because its id is the
  # unique key the row is indexed by, so it has to exist before anything is
  # persisted. Message#rumor rebuilds the identical structure at send time.
  class OutboundBuilder
    Result = Data.define(:message, :error) do
      def ok? = error.nil?
    end

    def initialize(conversation)
      @conversation = conversation
      @account = conversation.account
    end

    # `legacy_ack:` must be true to build a kind-4 downgrade. The model rejects an
    # unacknowledged one anyway; this just fails earlier and more clearly.
    def build(content:, reply_to: nil, legacy_ack: false)
      content = content.to_s.strip
      return Result.new(message: nil, error: "Write a message first.") if content.blank?

      if @conversation.legacy? && !legacy_ack
        return Result.new(message: nil, error: "Sending a legacy message needs an explicit confirmation.")
      end

      # The downgrade is offered from a NIP-17 room whose peer turned out to have
      # no kind 10050. Deciding legacy-vs-NIP-17 from the room alone ignored that
      # acknowledgement and built a NIP-17 message with nowhere to deliver it,
      # which then failed at send time — so the acknowledgement decides, and the
      # message moves to the legacy room for the same peer.
      if legacy_ack && !@conversation.legacy?
        return build_in_legacy_room(content)
      end

      message = @conversation.legacy? ? build_legacy(content) : build_nip17(content, reply_to)
      message.save!
      Result.new(message: message, error: nil)
    rescue ActiveRecord::RecordInvalid => e
      Result.new(message: nil, error: e.record.errors.full_messages.to_sentence)
    end

    private

    # Legacy threads are deliberately separate rooms: different security
    # properties and a different composer. Sending a downgrade from a NIP-17 room
    # therefore starts (or continues) the kind-4 thread with the same people.
    def build_in_legacy_room(content)
      legacy_room = @account.conversations.create_or_find_by!(
        protocol: "nip04",
        participants_key: @conversation.participants_key
      ) do |room|
        room.user = @conversation.user
        room.participant_pubkeys = @conversation.participant_pubkeys
        room.peer_pubkey = @conversation.peer_pubkey
        # Inherited: we are replying to someone we already have a thread with.
        room.classification = @conversation.classification
        room.classification_reason = @conversation.classification_reason
        room.last_message_at = Time.current
      end

      self.class.new(legacy_room).build(content: content, legacy_ack: true)
    end

    def build_nip17(content, reply_to)
      rumor = Nostr::Nip17.build_rumor(
        kind: Nostr::Nip17::CHAT_KIND,
        content: content,
        sender_pubkey: @account.pubkey_hex,
        recipients: @conversation.peer_pubkeys,
        reply_to: reply_to && { id: reply_to },
        subject: @conversation.subject
      )

      new_message(
        kind: Nostr::Nip17::CHAT_KIND,
        content: content,
        rumor_id: rumor["id"],
        rumor_created_at: Time.at(rumor["created_at"]).utc,
        raw_tags: rumor["tags"],
        reply_to_rumor_id: reply_to
      )
    end

    # A kind-4 DM has no rumor, so there is no NIP-01 id until the signer returns
    # the signed event. Use a placeholder that satisfies the unique index; the send
    # job replaces it with the real event id.
    def build_legacy(content)
      new_message(
        kind: Message::LEGACY_KIND,
        content: content,
        rumor_id: SecureRandom.hex(32),
        rumor_created_at: Time.current,
        raw_tags: [ [ "p", @conversation.peer_pubkeys.first ] ],
        legacy_downgrade_acked_at: Time.current
      )
    end

    def new_message(**attrs)
      @conversation.messages.new({
        account: @account,
        user: @conversation.user,
        sender_pubkey: @account.pubkey_hex,
        direction: "outbound",
        status: "pending",
        sort_at: Time.current,
        subject: @conversation.subject
      }.merge(attrs))
    end
  end
end
