# frozen_string_literal: true

# H11: fetching a kind-0 profile is a blocking relay round-trip (up to ~20s).
# Nostr::AuthService#find_or_create_user used to run it inline on first login,
# holding the 3s login poll open; now it just saves the bare user record and
# enqueues this job. The dashboard renders fine with the npub in the meantime
# and picks up the display name/picture on its next load once this lands.
class FetchUserProfileJob < ApplicationJob
  queue_as :default

  def perform(user_id)
    user = User.find_by(id: user_id)
    return unless user

    profile = Nostr::ProfileFetcher.new.fetch(user.pubkey_hex)
    return unless profile

    user.update(
      display_name: profile[:display_name],
      username: profile[:username],
      about: profile[:about],
      picture_url: profile[:picture]
    )
  end
end
