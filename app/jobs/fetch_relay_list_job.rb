# frozen_string_literal: true

class FetchRelayListJob < ApplicationJob
  queue_as :default

  def perform(account_id)
    account = Account.find(account_id)
    list = Nostr::RelayListFetcher.new.fetch_relay_list(account.pubkey_hex)

    # Only overwrite a half we actually got. A relay list that momentarily comes
    # back with no write entries must not wipe the relays we publish to.
    attrs = {}
    attrs[:write_relays] = list[:write] if list[:write].any?
    attrs[:read_relays] = list[:read] if list[:read].any?
    account.update(attrs) if attrs.any?
  end
end
