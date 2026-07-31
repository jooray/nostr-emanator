# frozen_string_literal: true

# One DM, inbound or outbound.
#
# Message bodies are stored decrypted-then-encrypted-at-rest: unwrapping a gift
# wrap costs two round-trips to the user's signer, so re-decrypting on every
# thread view would be unusable. The consequence to keep in mind is that losing
# ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY destroys the entire message history — a
# far larger blast radius than the existing encrypted columns.
class CreateMessages < ActiveRecord::Migration[8.1]
  def change
    create_table :messages do |t|
      t.references :conversation, null: false, foreign_key: true, index: false
      t.references :account, null: false, foreign_key: true, index: false
      t.references :user, null: false, foreign_key: true, index: false

      t.string :rumor_id, null: false, limit: 64
      t.integer :kind, null: false, default: 14      # 14 chat, 15 file, 4 legacy
      t.string :sender_pubkey, null: false, limit: 64

      # --- encrypted at rest (all text: ciphertext is much longer than plaintext)
      t.text :content
      t.text :subject
      # kind-15 carries decryption-key / decryption-nonce — whoever holds those
      # can decrypt the blob straight off the media server, so this is a secret.
      t.text :file_metadata
      # Tags name every participant, i.e. the social graph.
      t.text :raw_tags

      t.string :reply_to_rumor_id, limit: 64
      t.string :quoted_rumor_id, limit: 64

      t.datetime :rumor_created_at                   # what we display
      # min(rumor_created_at, seen_at). A hostile sender can date a rumor in 2030
      # and pin itself to the top of the inbox forever; ordering by this instead
      # makes that impossible while still showing the sender's own timestamp.
      t.datetime :sort_at, null: false
      t.datetime :seal_created_at                    # randomised; kept for forensics

      t.string :wrap_id, limit: 64                   # NULL until an outbound wrap exists
      t.string :direction, null: false, limit: 3     # "in" | "out"
      # in: received. out: pending, sealing, wrapping, publishing, sent, failed
      t.string :status, null: false, limit: 16, default: "received"
      t.json :publish_results
      t.string :step                                 # human-readable progress line
      t.string :error

      # Leniency flags, so a support question about a mismatched id has an answer.
      t.boolean :pubkey_recovered, null: false, default: false
      t.boolean :rumor_id_recomputed, null: false, default: false

      t.timestamps
    end

    # THE idempotency key. The self-addressed copy of an outbound message comes
    # back through our own inbound subscription carrying the same rumor id, so
    # without this every sent message would appear twice.
    add_index :messages, [ :account_id, :rumor_id ], unique: true, name: "idx_messages_rumor"
    add_index :messages, [ :conversation_id, :sort_at ], name: "idx_messages_thread"
    add_index :messages, [ :status, :updated_at ], name: "idx_messages_sweep"
    add_index :messages, [ :user_id, :direction, :sort_at ], name: "idx_messages_user_direction"
  end
end
