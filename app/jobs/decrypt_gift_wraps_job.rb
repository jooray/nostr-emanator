# frozen_string_literal: true

# Unwraps pending gift wraps for one account through its remote signer.
#
# Each wrap costs TWO nip44_decrypt round-trips (wrap -> seal, seal -> rumor) and
# the hops are inherently serial, since hop 2 needs hop 1's output to know whose
# key to derive against. Throughput therefore comes from having several wraps in
# flight, never from parallelising a single wrap.
#
# The concurrency cap is a safety limit rather than a tuning knob: Amber sleeps at
# least 200 ms before publishing any response, so it bounds the rate anyway — but
# it is also the thing standing between a large backfill and a wedged signer
# (greenart7c3/Amber#169 is a crash report from exactly this shape of load).
class DecryptGiftWrapsJob < ApplicationJob
  queue_as :messaging

  discard_on ActiveRecord::RecordNotFound

  def perform(account_id)
    account = Account.find(account_id)
    return unless account.messaging_capable?
    return unless account.gift_wraps.pending.exists?

    # One decrypt run per account at a time. A second job would contend for the
    # same rows and double the load on the signer for no gain.
    return unless InteractionsCache.claim_inflight(:dm_decrypt, account.id)

    sync = DmSyncState.for_account(account)
    sync.update!(status: "decrypting")
    decrypt_all(account, sync)
    sync.finish!
  rescue StandardError => e
    Rails.logger.error("Gift wrap decryption failed for account #{account_id}: #{e.class} - #{e.message}")
    DmSyncState.for_account(account).fail!(e.message) if account
  ensure
    InteractionsCache.release_inflight(:dm_decrypt, account_id)
  end

  private

  def decrypt_all(account, sync)
    settings = messaging_settings
    processed = 0
    remaining_budget = daily_budget_remaining(account, settings)

    Nostr::Nip46Rpc.open(account, max_in_flight: settings[:decrypt_concurrency]) do |rpc|
      ingestor = Messaging::MessageIngestor.new(account)

      loop do
        break if remaining_budget <= 0

        batch = account.gift_wraps.queue.limit([ settings[:decrypt_batch_size], remaining_budget ].min).to_a
        break if batch.empty?

        claimed = batch.select(&:claim!)
        break if claimed.empty?

        sync.progress!(
          step: "Decrypting messages in your signer app… #{processed} done, #{account.gift_wraps.pending.count} to go.",
          pending: account.gift_wraps.pending.count,
          processed: processed
        )

        outcomes = rpc.call_many(claimed) { |wrap| unwrap(rpc, ingestor, wrap) }

        processed += claimed.size
        remaining_budget -= claimed.size
        consume_daily_budget(account, claimed.size)

        # A batch where every wrap deferred means the signer is unreachable, not
        # that these particular wraps are bad. Stop and let the next scheduled run
        # retry: deferred wraps go straight back to `pending`, so continuing would
        # re-pick the same rows and burn all MAX_ATTEMPTS inside one run — while
        # flooding a signer that is already struggling.
        break if outcomes.map(&:value).all?(:deferred)
      end
    end

    sync.progress!(step: nil, processed: processed, pending: account.gift_wraps.pending.count)
    processed
  end

  # Runs on a Nip46Rpc worker thread. Holds no ActiveRecord connection across a
  # signer call — each persist checks one out and gives it straight back.
  #
  # Returns :decoded, :rejected or :deferred so the batch loop can tell "these
  # wraps are bad" from "the signer is down".
  def unwrap(rpc, ingestor, wrap)
    event = wrap.wrap_event
    raise "gift wrap event missing" if event.blank?

    seal_json = rpc.call("nip44_decrypt", [ event["pubkey"], event["content"] ])
    seal = Nostr::Nip17.parse_seal(seal_json)
    rumor_json = rpc.call("nip44_decrypt", [ seal["pubkey"], seal["content"] ])

    parsed = Nostr::Nip17.parse_rumor(
      rumor_json, seal: seal, recipient_pubkey: wrap.account.pubkey_hex, wrap_event: event
    )

    ActiveRecord::Base.connection_pool.with_connection do
      message = ingestor.ingest(parsed, wrap_id: wrap.wrap_id, seen_at: wrap.seen_at)
      # A duplicate rumor (the self-copy of something we sent) is still a
      # successfully resolved wrap — just one that produced no new bubble.
      wrap.decode!(message || existing_message(wrap, parsed))
    end
    :decoded
  rescue Nostr::Nip17::RejectedError => e
    # Malformed or hostile. Never retried: it cannot become valid, and a retry
    # would spend two more signer round-trips to learn the same thing.
    ActiveRecord::Base.connection_pool.with_connection { wrap.reject!(e.reason) }
    :rejected
  rescue Nostr::Nip44::Error, Nostr::Nip44::DecryptionError => e
    # Not addressed to us, or not a NIP-44 payload at all.
    ActiveRecord::Base.connection_pool.with_connection { wrap.reject!("undecryptable: #{e.class}") }
    :rejected
  rescue StandardError => e
    # Signer timeout, socket drop, relay hiccup — retryable.
    ActiveRecord::Base.connection_pool.with_connection { wrap.defer!(e.message) }
    :deferred
  end

  def existing_message(wrap, parsed)
    Message.find_by(account_id: wrap.account_id, rumor_id: parsed.rumor_id)
  end

  def messaging_settings
    config = Rails.application.config_for(:emanator).dig(:messaging) || {}
    {
      decrypt_concurrency: config[:decrypt_concurrency] || 6,
      decrypt_batch_size: config[:decrypt_batch_size] || 50,
      decrypt_daily_cap: config[:decrypt_daily_cap] || 1500
    }
  end

  # A 5000-wrap spam history must not drain the user's phone battery in one run.
  def daily_budget_remaining(account, settings)
    used = Rails.cache.read(budget_key(account)).to_i
    [ settings[:decrypt_daily_cap] - used, 0 ].max
  end

  def consume_daily_budget(account, count)
    Rails.cache.increment(budget_key(account), count, expires_in: 1.day, initial: 0)
  end

  def budget_key(account) = "dm_decrypt_budget_#{account.id}_#{Date.current}"
end
