# frozen_string_literal: true

class CreateNostrAuthSessions < ActiveRecord::Migration[8.0]
  def change
    create_table :nostr_auth_sessions do |t|
      t.string :session_id, null: false, index: { unique: true }
      t.string :temp_pubkey, null: false
      t.string :temp_privkey, null: false
      t.string :secret, null: false
      t.string :relay_url, null: false
      t.string :authenticated_pubkey
      t.datetime :expires_at, null: false
      t.timestamps
    end

    add_index :nostr_auth_sessions, :expires_at
  end
end
