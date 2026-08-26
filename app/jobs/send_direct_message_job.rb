# frozen_string_literal: true

# Seals, wraps and publishes one outbound NIP-17 message.
#
# Cost per recipient: one nip44_encrypt and one sign_event:13 in the signer. The
# gift wrap itself is encrypted AND signed locally with a throwaway key — that is
# what hides the sender from the relay, and it is why a 1:1 DM is four signer
# round-trips (peer + self-copy) rather than six.
#
# Runs on :messaging, not :signing. The signing pool has two threads and is
# deliberately reserved for post signing; a chatty DM session there would
# head-of-line-block scheduled posts.
class SendDirectMessageJob < ApplicationJob
  queue_as :messaging

  discard_on ActiveRecord::RecordNotFound

  def perform(message_id)
    message = Message.find(message_id)
    return unless message.outbound?
    # Lost the race to a retry that is already sending this message.
    return unless message.transition_status(from: :pending, to: :sealing)

    account = message.account
    recipients = recipients_for(message)

    # No longer refuses when the recipient published no kind 10050. Taken
    # literally that rule blocks roughly two thirds of real contacts, and it is
    # incoherent beside the kind-4 downgrade we offer instead — see
    # DmRelayListService#publish_targets. The tier that carried the message is
    # recorded so the UI can be honest about it.
    deliver(message, account, recipients)
  rescue StandardError => e
    Rails.logger.error("DM send failed for message #{message_id}: #{e.class} - #{e.message}")
    message&.update(status: "failed", error: e.message.truncate(240), step: nil)
    broadcast(message) if message
  end

  private

  # Every other participant, plus ourselves. The self-copy is how our own other
  # clients and devices see what we sent — NIP-17 has no other sent-history.
  def recipients_for(message)
    (message.conversation.peer_pubkeys + [ message.account.pubkey_hex ]).uniq
  end

  def deliver(message, account, recipients)
    rumor_json = JSON.generate(message.rumor)
    results = {}
    tiers = {}
    self_pubkey = account.pubkey_hex

    Nostr::Nip46Rpc.open(account) do |rpc|
      recipients.each_with_index do |recipient, index|
        message.update!(
          status: "sealing",
          step: "Approve the message in your signer app (#{index + 1} of #{recipients.size})…"
        )
        broadcast(message)

        wrap = seal_and_wrap(rpc, account, rumor_json, recipient)

        message.update!(status: "publishing", step: "Delivering to #{recipient.first(12)}…")
        broadcast(message)
        targets = targets_for(message, recipient)
        outcome = publish(wrap, targets)
        tiers[recipient] = effective_tier(targets, outcome)
        results[recipient] = outcome
      end
    end

    finish(message, results, tiers, self_pubkey)
  end

  # Their published inbox, plus the relays we have actually seen this peer's own
  # wraps arrive on. The observed ones are appended, never substituted: a kind
  # 10050 stays authoritative about where they asked to be reached, and this only
  # adds places they demonstrably publish to. For a Keychat contact — who has no
  # 10050 at all — it is the only accurate route we have.
  def targets_for(message, recipient)
    observed = Messaging::ObservedRelays.for(message.conversation, recipient)
    Nostr::DmRelayListService.new.publish_targets(recipient, observed: observed)
  end

  def seal_and_wrap(rpc, account, rumor_json, recipient)
    sealed = rpc.call("nip44_encrypt", [ recipient, rumor_json ])
    unsigned_seal = Nostr::Nip17.build_seal(sealed_content: sealed, sender_pubkey: account.pubkey_hex)
    signed_seal = JSON.parse(rpc.call("sign_event", [ JSON.generate(unsigned_seal) ]))

    # Same discipline as EventSignerService#valid_signed_event?: a signer that
    # altered what we asked it to sign must not be trusted.
    unless Nostr::EventValidator.valid?(signed_seal, kind: Nostr::Nip17::SEAL_KIND, author: account.pubkey_hex) &&
           %w[content tags created_at].all? { |field| signed_seal[field] == unsigned_seal[field] }
      raise "signer returned an altered seal"
    end

    Nostr::Nip17.build_wrap(seal: signed_seal, recipient_pubkey: recipient)
  end

  # include_defaults: false so the wrap reaches exactly the relays chosen above
  # and nothing else. The configured defaults would otherwise be folded in
  # unconditionally, which is a different decision from the tiered fallback —
  # that one is deliberate and recorded, this one would be invisible.
  def publish(wrap, targets)
    return {} unless targets.any?

    results = Nostr::EventPublisherService.new.publish(
      wrap, relays: targets.relays, include_defaults: false
    )

    # Learn which observed relays have started refusing us, so the next reply to
    # this peer does not spend an attempt on them again. Only the observed ones:
    # a relay the recipient nominated themselves is theirs to keep choosing.
    targets.observed.each { |url| Nostr::RelayWriteBlock.observe!(url, results[url]) }

    results
  end

  # A peer with no published inbox is normally best-effort — we are guessing from
  # their NIP-65 list or from popular relays, and the badge says "may not arrive".
  # That warning is wrong once an observed relay actually took the wrap: we saw
  # this peer's own messages arrive there, and both clients that make this
  # necessary read from the same pool they write to. Recording it as its own tier
  # keeps the badge honest in both directions — it is better evidence than
  # `nip65` or `fallback`, and still not the inbox they never published.
  def effective_tier(targets, results)
    return targets.tier if targets.tier == :inbox
    return targets.tier unless targets.observed.any? { |url| results[url] == :ok }

    :observed
  end

  def finish(message, results, tiers, self_pubkey)
    peer_results = results.except(self_pubkey)
    delivered = peer_results.values.any? { |r| r.value?(:ok) }
    # A note-to-self thread has no peer, so the self-copy is the delivery.
    delivered ||= results[self_pubkey]&.value?(:ok) if peer_results.empty?

    if delivered
      message.update!(
        status: "sent", step: nil, error: nil,
        publish_results: flatten(results), delivery_tier: worst_tier(tiers, self_pubkey)
      )
      mark_conversation_replied(message)
    else
      message.update!(
        status: "failed", step: nil, publish_results: flatten(results),
        error: "No relay accepted the message."
      )
    end

    broadcast(message)
  end

  def broadcast(message)
    Messaging::ThreadBroadcaster.refresh(message.conversation)
  end

  # The weakest tier any peer needed — one participant without a published inbox
  # makes the whole message best-effort, and the badge should say so rather than
  # average it away. The self-copy is excluded even for a note-to-self thread:
  # our own inbound subscription spans our NIP-65 read relays and the configured
  # defaults, so the self-copy lands somewhere we listen no matter which tier
  # carried it — a "may not arrive" badge there would warn about a delivery that
  # works. A note-to-self therefore gets no tier (nil), hence no badge.
  def worst_tier(tiers, self_pubkey)
    order = %w[fallback nip65 observed inbox]
    tiers.except(self_pubkey).values.map(&:to_s).min_by { |tier| order.index(tier) || 0 }
  end

  def flatten(results)
    results.transform_values { |per_relay| per_relay.transform_values(&:to_s) }
  end

  # Writing in a thread vouches for it: one of the Known rules.
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
