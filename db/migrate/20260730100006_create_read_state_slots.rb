# frozen_string_literal: true

# NIP-RS cross-device read state (kind 30078, `d: read-state:<slot-id>`).
#
# There is no standard for syncing DM read state between Nostr clients — three
# NIP attempts exist and two were withdrawn by their own author. NIP-RS (Block's
# Buzz) is the one rigorous spec, and it is a grow-only max-register CRDT: the
# merged value for a context is max() across every slot, and a timestamp is never
# lowered. Our own row is `own: true`; other devices' rows are imported as peers.
#
# https://github.com/block/buzz/blob/master/docs/nips/NIP-RS.md
class CreateReadStateSlots < ActiveRecord::Migration[8.1]
  def change
    create_table :read_state_slots do |t|
      # Per account, not per user: the spec asks multi-identity clients to use
      # distinct slot and client ids per pubkey.
      t.references :account, null: false, foreign_key: true, index: false

      t.string :slot_id, null: false, limit: 64
      t.string :client_id, limit: 64
      t.boolean :own, null: false, default: false

      # { "<context-id>": <unix-ts> }. Encrypted at rest: context ids are peer
      # pubkeys, i.e. who this account talks to.
      t.text :contexts

      t.integer :version, null: false, default: 1
      t.string :event_id, limit: 64
      t.datetime :last_published_at
      t.integer :last_seen_event_created_at

      # Debounced publishing: a cursor moves on every thread open, and each
      # publish costs an encrypt plus a sign.
      t.boolean :dirty, null: false, default: false
      t.datetime :publish_after

      t.timestamps
    end

    add_index :read_state_slots, [ :account_id, :slot_id ], unique: true, name: "idx_read_state_slots_slot"
    add_index :read_state_slots, [ :account_id, :own ], name: "idx_read_state_slots_own"
    add_index :read_state_slots, [ :dirty, :publish_after ], name: "idx_read_state_slots_flush"
  end
end
