# frozen_string_literal: true

# Dedupe ledger for inbound kind-1059 gift wraps.
#
# The same wrap arrives from every relay in the account's inbox list, and each
# one costs TWO nip44_decrypt round-trips to the user's phone. This table is the
# thing that makes that spend happen exactly once per wrap, ever.
class CreateGiftWraps < ActiveRecord::Migration[8.1]
  def change
    create_table :gift_wraps do |t|
      t.references :account, null: false, foreign_key: true, index: false

      t.string :wrap_id, null: false, limit: 64
      t.datetime :wrap_created_at                 # randomised up to 2 days back

      # pending | decrypting | decoded | undecryptable | rejected
      t.string :status, null: false, limit: 16, default: "pending"
      t.integer :attempts, null: false, default: 0
      t.string :last_error

      # Plain integer, not a foreign key: a deleted message must not block the
      # ledger row that records we already paid to decrypt this wrap.
      t.bigint :message_id

      t.json :relays, null: false, default: []    # where we saw it
      t.datetime :seen_at, null: false

      # The full 1059 event, unencrypted — it is public relay data, and keeping it
      # means a retry after the signer was offline needs no refetch. Nulled once
      # the wrap reaches `decoded` so this does not grow without bound.
      t.json :wrap_event

      t.timestamps
    end

    add_index :gift_wraps, [ :account_id, :wrap_id ], unique: true, name: "idx_gift_wraps_wrap"
    add_index :gift_wraps, [ :account_id, :status, :wrap_created_at ], name: "idx_gift_wraps_queue"
    add_index :gift_wraps, [ :status, :updated_at ], name: "idx_gift_wraps_sweep"
  end
end
