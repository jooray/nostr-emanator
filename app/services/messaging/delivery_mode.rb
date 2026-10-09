# frozen_string_literal: true

module Messaging
  # How (and whether) a reply in a thread can be delivered. Cache reads only —
  # never relay I/O in a request. Shared by the web composer and the app.
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
  module DeliveryMode
    def self.for(conversation)
      return :unavailable unless conversation.account.messaging_capable?

      peer = conversation.peer_pubkeys.first
      return :self if peer.blank?
      return :legacy if conversation.legacy?

      list = Nostr::DmRelayListService.new.cached(peer)

      if list.nil? || list.stale?
        RefreshDmRelayListJob.perform_later(peer)
        return list&.deliverable? ? :nip17 : :checking
      end

      list.deliverable? ? :nip17 : :best_effort
    end

    # True when a private retry cannot possibly work: the peer has published no
    # kind 10050, so there is no relay a gift wrap could be delivered to.
    def self.undeliverable_privately?(message)
      return false if message.kind == Message::LEGACY_KIND

      peer = message.conversation.peer_pubkeys.first
      return false if peer.blank?

      list = Nostr::DmRelayListService.new.cached(peer)
      list.present? && !list.deliverable?
    end

    def self.enqueue(message)
      if message.legacy_downgrade?
        SendLegacyDirectMessageJob.perform_later(message.id)
      else
        SendDirectMessageJob.perform_later(message.id)
      end
    end
  end
end
