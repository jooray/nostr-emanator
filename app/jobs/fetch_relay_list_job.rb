# frozen_string_literal: true

class FetchRelayListJob < ApplicationJob
  queue_as :default

  def perform(account_id)
    account = Account.find(account_id)
    relays = Nostr::RelayListFetcher.new.fetch_write_relays(account.pubkey_hex)
    account.update(write_relays: relays) if relays.any?
  end
end
