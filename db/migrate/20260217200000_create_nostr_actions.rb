# frozen_string_literal: true

class CreateNostrActions < ActiveRecord::Migration[8.0]
  def change
    create_table :nostr_actions do |t|
      t.references :account, null: false, foreign_key: true
      t.integer :action_type, null: false
      t.integer :status, default: 0
      t.string :target_event_id
      t.string :target_pubkey, null: false
      t.integer :target_event_kind, default: 1
      t.json :unsigned_event
      t.json :signed_event
      t.string :event_id
      t.json :publish_results
      t.string :error_message
      t.timestamps
    end

    add_index :nostr_actions, [:account_id, :action_type, :status]
    add_index :nostr_actions, [:account_id, :target_event_id]
    add_index :nostr_actions, [:account_id, :target_pubkey]
  end
end
