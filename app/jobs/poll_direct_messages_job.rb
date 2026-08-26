# frozen_string_literal: true

# Pulls inbound kind-1059 gift wraps for every messaging-enabled account and
# records them in the dedupe ledger. Decryption is a separate job: this one must
# never block on the signer.
#
# Until the persistent DM supervisor exists this is the whole inbound path; after
# that it stays as the safety net for when the supervisor is down (mid-deploy,
# lock lost), in the same spirit as ensure_nip46_supervisor.
class PollDirectMessagesJob < ApplicationJob
  queue_as :messaging

  # A quiet cap so one account with a huge backlog cannot monopolise a run.
  PAGE_LIMIT = 200

  def perform(account_id = nil)
    accounts = account_id ? Account.where(id: account_id) : Account.messaging
    accounts.find_each { |account| poll(account) }
  end

  private

  # Resolve where this account's OWN messages are supposed to land, before
  # deciding what to listen on.
  #
  # Without this we would only ever poll the app's configured relays: nothing else
  # fetches an account's own kind 10050, and read_relays stays empty until a
  # NIP-65 refresh happens to run. Emanator does not create identities, so the DM
  # inbox these accounts already published from Amethyst or 0xchat is exactly the
  # place their messages are.
  def refresh_own_relay_lists(account)
    service = Nostr::DmRelayListService.new
    list = service.cached(account.pubkey_hex)
    service.fetch!(account.pubkey_hex) if list.nil? || list.stale?

    if Array(account.read_relays).empty?
      relay_list = Nostr::RelayListFetcher.new.fetch_relay_list(account.pubkey_hex)
      updates = {}
      updates[:read_relays] = relay_list[:read] if relay_list[:read].any?
      updates[:write_relays] = relay_list[:write] if relay_list[:write].any? && Array(account.write_relays).empty?
      account.update!(updates) if updates.any?
    end
  rescue StandardError => e
    # Never fatal: we can still poll the configured relays.
    Rails.logger.warn("Could not refresh DM relay lists for account #{account.id}: #{e.message}")
  end

  def poll(account)
    return unless account.messaging_capable?

    sync = DmSyncState.for_account(account)
    refresh_own_relay_lists(account)
    relays = Nostr::DmRelayListService.new.inbox_relays_for(account)

    # Legacy kind-4 threads live on the account's ordinary relays, not on a DM
    # inbox — and most identities have never published a kind 10050, so this is
    # where the whole of their message history actually is.
    ImportLegacyDmsJob.perform_later(account.id) if account.legacy_dm_import?

    if relays.empty?
      # Nothing to listen on yet. Not an error: the account has no published
      # 10050 and no NIP-65 read relays, so nobody can reach it anyway.
      sync.progress!(step: "No DM inbox relays known for this account yet.")
      return
    end

    since = backfill_since(sync, relays)
    wraps = fetch_wraps(account, relays, since)
    stored = wraps.count { |(event, seen_on)| record(account, event, seen_on) }
    sync.observe_relays!(relays)

    sync.observe_wrap!(newest_seen_at(wraps))
    sync.progress!(step: stored.positive? ? "Found #{stored} new message(s)." : nil,
                   pending: account.gift_wraps.pending.count)

    DecryptGiftWrapsJob.perform_later(account.id) if account.gift_wraps.pending.exists?
  rescue StandardError => e
    Rails.logger.error("DM poll failed for account #{account.id}: #{e.class} - #{e.message}")
    DmSyncState.for_account(account).fail!(e.message)
  end

  def fetch_wraps(account, relays, since)
    filter = {
      "kinds" => [ Nostr::Nip17::WRAP_KIND ],
      "#p" => [ account.pubkey_hex ],
      "since" => since,
      "limit" => PAGE_LIMIT
    }

    threads = relays.map do |relay_url|
      Thread.new do
        # verify: true still applies — RelayQuery checks the id and signature, and
        # that the kind was one we asked for. It cannot check the author, because
        # a gift wrap is signed by a throwaway key by design.
        events = Nostr::RelayQuery.run(
          relay_url, filter, timeout: 8, kind: Nostr::Nip17::WRAP_KIND,
          auth: auth_callback(account)
        ) || []
        events.map { |event| [ event, relay_url ] }
      rescue StandardError => e
        Rails.logger.warn("Gift wrap fetch failed on #{relay_url.inspect}: #{e.message}")
        []
      end
    end

    # Which relay each wrap came from is the evidence a reply is routed by, so
    # the dedupe keeps every sighting rather than collapsing to one event. Same
    # wrap from four relays is four rows here and one GiftWrap row after
    # `record`, which folds the extra relays in via `observed_on!`.
    threads.flat_map(&:value).uniq { |(event, relay_url)| [ event["id"], relay_url ] }
  end

  # `since` is one watermark for the whole account, so it says nothing useful
  # about a relay we have only just started listening to: everything already
  # sitting there is older than the watermark and would be skipped forever.
  #
  # When the relay set changes, do one deep pass. It costs bandwidth and nothing
  # else — wrap_id uniqueness means an already-recorded wrap is not decrypted
  # again, and decryption is the only expensive part.
  def backfill_since(sync, relays)
    return sync.since if sync.relays_unchanged?(relays)

    Rails.logger.info("DM poll: relay set changed for account #{sync.account_id}, re-scanning from scratch")
    DmSyncState::MAX_BACKFILL_AGE.ago.to_i
  end

  # NIP-42 signer callback. Two of the commonly-listed DM inbox relays refuse to
  # serve kind 1059 without it, so an account whose 10050 points there would
  # otherwise show a permanently empty inbox.
  def auth_callback(account)
    lambda do |relay_url, challenge|
      # Amber AUTO-REJECTS kind 22242 when the user has a non-empty relay-auth
      # whitelist that omits this relay. Re-prompting every poll would be
      # pointless noise, so a refusal is remembered and surfaced in the UI.
      next nil if Nostr::RelayAuth.rejected?(relay_url, account.pubkey_hex)

      unsigned = Nostr::RelayAuth.build_unsigned(
        relay_url: relay_url, challenge: challenge, pubkey: account.pubkey_hex
      )
      signed = Nostr::EventSignerService.new.request_signature(account, unsigned)

      if signed
        Nostr::RelayAuth.remember_result!(relay_url, account.pubkey_hex, :ok)
        account.clear_relay_auth_blocked!(Nostr::RelayAuth.host(relay_url))
      else
        Nostr::RelayAuth.remember_result!(relay_url, account.pubkey_hex, :rejected)
        account.mark_relay_auth_blocked!(Nostr::RelayAuth.host(relay_url))
      end

      signed
    end
  end

  # Returns true when this wrap was new to us.
  def record(account, event, seen_on)
    return false unless Nostr::Nip17.valid_wrap?(event, recipient_pubkey: account.pubkey_hex)

    wrap = account.gift_wraps.create_or_find_by!(wrap_id: event["id"]) do |record|
      record.wrap_created_at = Time.at(event["created_at"].to_i).utc
      record.seen_at = Time.current
      record.wrap_event = event
      record.relays = [ seen_on ].compact
    end

    fresh = wrap.previously_new_record?
    wrap.observed_on!(seen_on) unless fresh
    fresh
  rescue ActiveRecord::RecordNotUnique
    false
  end

  # The outer created_at is randomised into the past, so it is useless as a
  # watermark. Track when *we* saw it instead.
  def newest_seen_at(wraps)
    Time.current if wraps.any?
  end
end
