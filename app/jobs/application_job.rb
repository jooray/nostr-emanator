class ApplicationJob < ActiveJob::Base
  # Automatically retry jobs that encountered a deadlock
  # retry_on ActiveRecord::Deadlocked

  # Most jobs are safe to ignore if the underlying records are no longer available
  # discard_on ActiveJob::DeserializationError

  private

  # M4 (defense in depth): the signed event was verified when the signer
  # returned it, but it then sits in the database until publish time. Re-check
  # id + Schnorr signature + author immediately before it goes to the relays,
  # so a tampered or mixed-up row can never be published under an account's
  # key. Returns false (and logs) when the event must not be published.
  def signed_event_verified?(record)
    return true if Nostr::EventValidator.valid?(record.signed_event, author: record.account.pubkey_hex)

    Rails.logger.error(
      "#{self.class.name}: refusing to publish #{record.class.name} #{record.id} — " \
      "stored signature does not verify for #{record.account.pubkey_hex}"
    )
    false
  end
end
