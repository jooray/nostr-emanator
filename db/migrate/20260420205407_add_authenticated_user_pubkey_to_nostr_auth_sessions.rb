class AddAuthenticatedUserPubkeyToNostrAuthSessions < ActiveRecord::Migration[8.1]
  def change
    add_column :nostr_auth_sessions, :authenticated_user_pubkey, :string
  end
end
