# frozen_string_literal: true

# Sends one legacy NIP-04 (kind 4) direct message.
#
# This exists only because a recipient with no kind 10050 cannot receive NIP-17 at
# all — notably every Damus user, since Damus still has no NIP-17 support. It is a
# genuine downgrade and the user has acknowledged it (Message validates that), so
# this job never has to decide whether it is allowed.
#
# Separate from SendDirectMessageJob rather than a branch inside it: no rumor, no
# seal, no gift wrap, no self-copy, and the opposite relay policy. They share
# almost nothing but the queue.
class SendLegacyDirectMessageJob < ApplicationJob
  queue_as :messaging

  discard_on ActiveRecord::RecordNotFound

  def perform(message_id)
    message = Message.find(message_id)
    return unless message.legacy_downgrade?
    return unless message.legacy_downgrade_acked_at.present?
    return unless message.transition_status(from: :pending, to: :sealing)

    account = message.account
    recipient = message.conversation.peer_pubkeys.first
    return message.update!(status: "failed", step: nil, error: "No recipient.") if recipient.blank?

    signed = encrypt_and_sign(message, account, recipient)
    return message.update!(status: "failed", step: nil, error: "Your signer did not return a signed message.") unless signed

    publish(message, account, recipient, signed)
  rescue StandardError => e
    Rails.logger.error("Legacy DM send failed for message #{message_id}: #{e.class} - #{e.message}")
    message&.update(status: "failed", error: e.message.truncate(240), step: nil)
  end

  private

  def encrypt_and_sign(message, account, recipient)
    Nostr::Nip46Rpc.open(account) do |rpc|
      message.update!(step: "Approve the message in your signer app (1 of 2)…")
      ciphertext = rpc.call("nip04_encrypt", [ recipient, message.content ])

      unsigned = Nostr::EventSignerService.new.build_unsigned_event(
        content: ciphertext, kind: Message::LEGACY_KIND, pubkey: account.pubkey_hex,
        created_at: Time.now.to_i, tags: [ [ "p", recipient ] ]
      )

      message.update!(status: "wrapping", step: "Approve the signature in your signer app (2 of 2)…")
      signed = JSON.parse(rpc.call("sign_event", [ JSON.generate(unsigned) ]))

      next nil unless Nostr::EventValidator.valid?(signed, kind: Message::LEGACY_KIND, author: account.pubkey_hex)

      signed
    end
  end

  # The inverse of a gift wrap's relay policy. A kind 4 puts the sender, the
  # recipient and the timestamp in the clear by construction, so there is no
  # metadata left to protect by restricting relays — and the recipient's NIP-65
  # READ relays are exactly where they expect to be reached. Defaults included.
  def publish(message, account, recipient, signed)
    message.update!(status: "publishing", step: "Delivering…")

    relays = (recipient_read_relays(recipient) + Array(account.write_relays)).uniq
    results = Nostr::EventPublisherService.new.publish(signed, relays: relays)

    if results.value?(:ok)
      # A kind 4 has no rumor, so the real event id only exists now. Replace the
      # placeholder so an inbound copy of this same event deduplicates against it.
      message.update!(
        status: "sent", step: nil, error: nil,
        rumor_id: signed["id"], publish_results: results.transform_values(&:to_s)
      )
      mark_conversation_replied(message)
    else
      message.update!(
        status: "failed", step: nil,
        publish_results: results.transform_values(&:to_s),
        error: "No relay accepted the message."
      )
    end
  end

  def recipient_read_relays(recipient)
    Nostr::RelayListFetcher.new.fetch_relay_list(recipient)[:read]
  rescue StandardError => e
    Rails.logger.warn("Could not resolve read relays for #{recipient.inspect}: #{e.message}")
    []
  end

  def mark_conversation_replied(message)
    conversation = message.conversation
    conversation.update!(
      has_replied: true,
      last_message_at: message.sort_at,
      last_message_preview: message.content.to_s.truncate(Messaging::MessageIngestor::PREVIEW_LENGTH),
      last_message_from_self: true
    )
    conversation.classify!("known", "replied") unless conversation.known?
  end
end
