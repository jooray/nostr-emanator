# frozen_string_literal: true

# H11: mirrors FetchRelayListJob but for the kind-0 profile. Pairing
# completion and the "Refresh Profile" button used to fetch this inline
# (accounts_controller.rb), blocking the request for up to ~20s on a relay
# round-trip. Now both just enqueue this and redirect immediately; the
# account page picks up the new display name/picture on its next load.
class FetchAccountProfileJob < ApplicationJob
  queue_as :default

  def perform(account_id)
    account = Account.find_by(id: account_id)
    return unless account

    profile = Nostr::ProfileFetcher.new.fetch(account.pubkey_hex)
    return unless profile

    account.update(
      display_name: profile[:display_name],
      username: profile[:username],
      about: profile[:about],
      picture_url: profile[:picture]
    )
  end
end
