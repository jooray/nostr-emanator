# frozen_string_literal: true

module Sessions
  # What happens once a pubkey has proven itself, whichever way it logged in:
  # web NIP-07, web NIP-46 (QR or bunker) or the native app's NIP-46.
  #
  # The user is created on first login, and the identity they logged in with is
  # imported as their first managed account — carrying the NIP-46 connection
  # when the login came through a signer, so it can post straight away.
  class Login
    def self.complete!(pubkey_hex, auth_session: nil)
      user = Nostr::AuthService.new.find_or_create_user(pubkey_hex)
      import_primary_account(user, auth_session)
      user
    end

    def self.import_primary_account(user, auth_session = nil)
      account = user.accounts.find_or_initialize_by(pubkey_hex: user.pubkey_hex)

      if account.new_record?
        account.display_name = user.display_name
        account.username = user.username
        account.about = user.about
        account.picture_url = user.picture_url
      end

      # Store NIP-46 connection details if login was via NIP-46
      account.apply_signer(auth_session) if auth_session&.authenticated_pubkey.present?

      account.save!

      # Fetch write relays in background
      FetchRelayListJob.perform_later(account.id) if account.write_relays.blank?
    rescue ActiveRecord::RecordNotUnique
      # L16: find_or_initialize_by + save! races another request importing the
      # same (user_id, pubkey_hex) account — e.g. an overlapping login poll.
      # Reload the row the other request created instead of 500ing.
      account = user.accounts.find_by!(pubkey_hex: user.pubkey_hex)
      FetchRelayListJob.perform_later(account.id) if account.write_relays.blank?
    end
  end
end
