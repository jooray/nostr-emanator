# frozen_string_literal: true

# The app's NIP-46 login has no cookie session to bind a poll to, so its
# creator gets a secret poll token; only the digest is stored.
class AddPollTokenDigestToNostrAuthSessions < ActiveRecord::Migration[8.1]
  def change
    add_column :nostr_auth_sessions, :poll_token_digest, :string
  end
end
