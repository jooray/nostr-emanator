# frozen_string_literal: true

# Names of the people a user's accounts follow, so the composer can look them
# up for an @mention without a relay round trip per keystroke.
class CreateNostrProfiles < ActiveRecord::Migration[8.1]
  def change
    create_table :nostr_profiles do |t|
      t.string :pubkey_hex, limit: 64, null: false
      t.string :name
      t.string :display_name
      t.string :nip05
      t.text :picture_url
      t.datetime :fetched_at, null: false
      t.timestamps
    end
    add_index :nostr_profiles, :pubkey_hex, unique: true
  end
end
