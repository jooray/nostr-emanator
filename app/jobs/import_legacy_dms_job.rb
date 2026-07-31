# frozen_string_literal: true

# Imports legacy NIP-04 (kind 4) DM history for one account.
#
# Opt-in per account, because it is the most signer-intensive thing in the app:
# one nip04_decrypt round-trip per message, and unlike gift wraps there is no
# spam filter in front of it. If the user's signer is not set to remember the
# decrypt permission, this is where the tapping hurts most.
#
# Both directions are fetched — messages TO us and messages FROM us — because a
# kind-4 thread only makes sense with both sides, and our own sent copies exist
# nowhere else.
class ImportLegacyDmsJob < ApplicationJob
  queue_as :messaging

  discard_on ActiveRecord::RecordNotFound

  MAX_EVENTS = 1_000
  MAX_AGE = 180.days

  def perform(account_id)
    account = Account.find(account_id)
    return unless account.messaging_capable?
    return unless account.legacy_dm_import?
    return unless InteractionsCache.claim_inflight(:legacy_dm_import, account.id)

    events = fetch(account)
    return if events.empty?

    sync = DmSyncState.for_account(account)
    sync.progress!(step: "Importing #{events.size} legacy message(s)…")
    import(account, events)
    sync.finish!
  rescue StandardError => e
    Rails.logger.error("Legacy DM import failed for account #{account_id}: #{e.class} - #{e.message}")
  ensure
    InteractionsCache.release_inflight(:legacy_dm_import, account_id)
  end

  private

  def fetch(account)
    since = MAX_AGE.ago.to_i
    # Their configured inbox — NIP-65 read relays are where a kind 4 addressed to
    # them is expected to land — plus their write relays for our own sent copies.
    fetcher = Nostr::EventFetcher.new(
      additional_relays: Array(account.read_relays) + Array(account.write_relays)
    )

    inbound = fetcher.fetch_events(
      { "kinds" => [ 4 ], "#p" => [ account.pubkey_hex ], "since" => since, "limit" => MAX_EVENTS }
    )
    outbound = fetcher.fetch_events(
      { "kinds" => [ 4 ], "authors" => [ account.pubkey_hex ], "since" => since, "limit" => MAX_EVENTS }
    )

    (inbound + outbound).uniq { |event| event["id"] }
      .sort_by { |event| -event["created_at"].to_i }
      .first(MAX_EVENTS)
  end

  def import(account, events)
    ingestor = Messaging::MessageIngestor.new(account)
    known = Message.where(account_id: account.id, kind: Message::LEGACY_KIND).pluck(:rumor_id).to_set

    Nostr::Nip46Rpc.open(account) do |rpc|
      events.each do |event|
        next if known.include?(event["id"])

        parsed = decrypt(rpc, account, event)
        next unless parsed

        ingestor.ingest(parsed, seen_at: Time.at(event["created_at"].to_i).utc, protocol: "nip04")
      end
    end
  end

  # A kind 4 is a plain signed event, so unlike a gift wrap the counterparty is
  # already public — the only secret is the text. One signer round-trip.
  def decrypt(rpc, account, event)
    peer = counterparty(account, event)
    return nil if peer.blank?

    plaintext = rpc.call("nip04_decrypt", [ peer, event["content"] ])
    return nil if plaintext.blank?

    participants = [ event["pubkey"], peer, account.pubkey_hex ].map(&:downcase).uniq.sort

    Nostr::Nip17::Message.new(
      kind: Message::LEGACY_KIND,
      sender_pubkey: event["pubkey"].downcase,
      content: plaintext,
      participants: participants,
      participants_key: Nostr::Nip17.participants_key(participants),
      subject: nil,
      reply_to_rumor_id: nil,
      quoted_rumor_id: nil,
      rumor_id: event["id"],
      rumor_created_at: event["created_at"],
      seal_created_at: nil,
      tags: Array(event["tags"]),
      file_metadata: nil,
      pubkey_recovered: false,
      rumor_id_recomputed: false
    )
  rescue StandardError => e
    Rails.logger.warn("Could not decrypt legacy DM #{event["id"].inspect}: #{e.message}")
    nil
  end

  # For a message we sent, the peer is the p-tag; for one we received, the author.
  def counterparty(account, event)
    return p_tag(event) if event["pubkey"]&.downcase == account.pubkey_hex.downcase

    event["pubkey"]
  end

  def p_tag(event)
    Array(event["tags"]).find { |tag| tag.is_a?(Array) && tag[0] == "p" }&.at(1)
  end
end
