# frozen_string_literal: true

# Cache of kind-10050 DM relay lists, for our own accounts and for everyone we
# talk to, keyed by pubkey.
#
# NIP-17 makes this load-bearing in both directions: clients MUST publish gift
# wraps only to the recipient's 10050 relays, and if a person has no 10050 they
# are simply not ready to receive DMs. `missing` is therefore a first-class UI
# state, not an error — the composer has to say so instead of failing silently.
class CreateDmRelayLists < ActiveRecord::Migration[8.1]
  def change
    create_table :dm_relay_lists do |t|
      # No owner reference: this is a global cache of public discovery documents,
      # including for pubkeys that are not accounts in this app.
      t.string :pubkey_hex, null: false, limit: 64

      # Already filtered through Security::UrlGuard and capped — these URLs are
      # attacker-supplied.
      t.json :relays, null: false, default: []
      t.datetime :event_created_at                # newest 10050 wins
      t.json :raw_event                           # needed to republish our own

      t.datetime :fetched_at
      t.boolean :missing, null: false, default: false
      t.datetime :checked_at

      t.timestamps
    end

    add_index :dm_relay_lists, :pubkey_hex, unique: true, name: "idx_dm_relay_lists_pubkey"
    add_index :dm_relay_lists, :fetched_at
  end
end
