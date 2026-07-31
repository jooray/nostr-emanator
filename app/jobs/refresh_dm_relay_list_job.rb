# frozen_string_literal: true

# Resolves one pubkey's kind-10050 DM relay list off the request path.
#
# The composer must never block on relay I/O, but it also must not treat "we have
# not looked yet" as "this person has no DM inbox" — that would push users onto
# the legacy NIP-04 downgrade because of a cold cache. So the request renders a
# "checking" state and enqueues this.
class RefreshDmRelayListJob < ApplicationJob
  queue_as :messaging

  def perform(pubkey_hex)
    # Short in-flight guard: several open threads with the same peer would
    # otherwise each fan out to the indexer relays.
    return unless InteractionsCache.claim_inflight(:dm_relay_list, pubkey_hex)

    Nostr::DmRelayListService.new.fetch!(pubkey_hex)
  ensure
    InteractionsCache.release_inflight(:dm_relay_list, pubkey_hex)
  end
end
