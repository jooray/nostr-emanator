# frozen_string_literal: true

class CreateAccounts < ActiveRecord::Migration[8.0]
  def change
    create_table :accounts do |t|
      t.references :user, null: false, foreign_key: true
      t.string :npub
      t.string :pubkey_hex, null: false
      t.string :display_name
      t.string :username
      t.text :about
      t.string :picture_url
      t.text :personality
      t.json :write_relays, default: []
      t.string :signer_pubkey
      t.string :signer_relay
      t.string :app_pubkey
      t.string :app_privkey
      t.json :settings, default: {}
      t.timestamps
    end

    add_index :accounts, [:user_id, :pubkey_hex], unique: true
  end
end
