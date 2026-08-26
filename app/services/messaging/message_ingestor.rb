# frozen_string_literal: true

module Messaging
  # Turns a decrypted Nostr::Nip17::Message into persisted rows.
  #
  # Idempotent by construction: a wrap re-delivered from another relay, a job
  # retry, and the self-addressed copy of something we sent all converge on the
  # same (account_id, rumor_id) row.
  class MessageIngestor
    PREVIEW_LENGTH = 140

    def initialize(account)
      @account = account
      @user = account.user
    end

    # Returns the Message, or nil when this rumor was already stored.
    def ingest(parsed, wrap_id: nil, seen_at: Time.current, protocol: "nip17", relays: [])
      conversation = upsert_conversation(parsed, seen_at, protocol)
      message = upsert_message(conversation, parsed, wrap_id, seen_at, relays)
      return nil unless message

      conversation.apply_subject(parsed.subject, message.sort_at)
      refresh_conversation(conversation, message)
      classify(conversation)
      ThreadBroadcaster.refresh(conversation)
      message
    end

    private

    def upsert_conversation(parsed, seen_at, protocol)
      conversation = @account.conversations.create_or_find_by!(
        protocol: protocol,
        participants_key: parsed.participants_key
      ) do |record|
        record.user = @user
        record.participant_pubkeys = parsed.participants
        record.peer_pubkey = peer_pubkey(parsed)
        record.classification = "request"
        record.classification_reason = "unclassified"
        record.last_message_at = seen_at
      end

      # create_or_find_by! skips the block on an existing row, and older rows may
      # predate a column, so backfill rather than assuming.
      if conversation.participant_pubkeys.blank?
        conversation.update!(participant_pubkeys: parsed.participants, peer_pubkey: peer_pubkey(parsed))
      end

      conversation
    end

    # NULL for groups: there is no single "other side" to render.
    def peer_pubkey(parsed)
      others = parsed.participants - [ @account.pubkey_hex.downcase ]
      others.size == 1 ? others.first : nil
    end

    def upsert_message(conversation, parsed, wrap_id, seen_at, relays)
      outbound = parsed.sender_pubkey == @account.pubkey_hex.downcase

      message = Message.create_or_find_by!(account_id: @account.id, rumor_id: parsed.rumor_id) do |record|
        record.conversation = conversation
        record.user = @user
        record.kind = parsed.kind
        record.sender_pubkey = parsed.sender_pubkey
        record.content = parsed.content
        record.subject = parsed.subject
        record.file_metadata = parsed.file_metadata
        record.raw_tags = parsed.tags
        record.reply_to_rumor_id = parsed.reply_to_rumor_id
        record.quoted_rumor_id = parsed.quoted_rumor_id
        record.rumor_created_at = timestamp(parsed.rumor_created_at)
        record.seal_created_at = timestamp(parsed.seal_created_at)
        record.sort_at = Message.sort_at_for(timestamp(parsed.rumor_created_at), seen_at)
        record.wrap_id = wrap_id
        # Copied off the gift wrap rather than joined to it: decode! drops the
        # wrap's cached event, and the ledger is swept, but where a peer's mail
        # arrives has to outlive both to be usable as a reply route.
        record.relays = Array(relays).uniq
        record.direction = outbound ? "outbound" : "inbound"
        record.status = outbound ? "sent" : "received"
        record.pubkey_recovered = parsed.pubkey_recovered
        record.rumor_id_recomputed = parsed.rumor_id_recomputed
      end

      # Already stored. The common case is the self-copy of a message we sent
      # arriving back through our own subscription — record which wrap carried it
      # and stop, rather than creating a duplicate bubble.
      unless message.previously_new_record?
        attrs = {}
        attrs[:wrap_id] = wrap_id if wrap_id.present? && message.wrap_id.blank?
        merged = (Array(message.relays) + Array(relays)).uniq
        attrs[:relays] = merged if merged != Array(message.relays)
        message.update!(attrs) if attrs.any?
        return nil
      end

      message
    end

    def refresh_conversation(conversation, message)
      from_self = message.outbound?
      attrs = {
        last_message_at: message.sort_at,
        last_message_preview: message.content.to_s.truncate(PREVIEW_LENGTH),
        last_message_from_self: from_self
      }
      # Our own messages are read by definition, and an outbound message means we
      # have written here — which is one of the Known rules.
      attrs[:has_replied] = true if from_self
      attrs[:unread_count] = conversation.unread_count + 1 unless from_self || read_already?(conversation, message)

      conversation.update!(attrs)
    end

    # A message older than our read cursor is history arriving late, not something
    # new to badge.
    def read_already?(conversation, message)
      conversation.last_read_at.present? && message.sort_at <= conversation.last_read_at
    end

    def classify(conversation)
      SenderClassifier.new(@user, wot: false).classify!(conversation)
    rescue StandardError => e
      # Classification is a nicety; never lose a message over it. The conversation
      # stays in Requests, which is the safe side.
      Rails.logger.warn("Classification failed for conversation #{conversation.id}: #{e.message}")
    end

    def timestamp(value)
      return nil if value.blank?

      Time.at(value.to_i).utc
    end
  end
end
