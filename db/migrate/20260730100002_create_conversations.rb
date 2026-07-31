# frozen_string_literal: true

# One DM room, owned by one paired account.
#
# NIP-17 has no room id: a room IS its participant set. Adding or removing a
# participant therefore starts a NEW room with clean history rather than editing
# an existing one, which is why `participants_key` (a hash of the sorted set) is
# the identity and part of the unique index.
class CreateConversations < ActiveRecord::Migration[8.1]
  def change
    create_table :conversations do |t|
      # user_id is denormalised on purpose: the whole point of the Messages tab
      # is one inbox across every account the user has paired, so nearly every
      # query starts from the user, not the account.
      t.references :user, null: false, foreign_key: true, index: false
      t.references :account, null: false, foreign_key: true, index: false

      # "nip17" | "nip04". Legacy kind-4 threads are never merged into NIP-17
      # rooms: different security properties, different reply targets, and we
      # never send kind 4 — so the composer has to behave differently.
      t.string :protocol, null: false, limit: 16, default: "nip17"

      t.string :participants_key, null: false, limit: 64
      t.json :participant_pubkeys, null: false, default: []
      t.string :peer_pubkey, limit: 64            # 1:1 only; NULL for groups

      # Encrypted: a room title is user content. text, not string — ciphertext is
      # a base64 JSON envelope several times longer than its plaintext.
      t.text :subject
      t.datetime :subject_updated_at             # newest `subject` tag wins

      # known | request | muted
      t.string :classification, null: false, limit: 16, default: "request"
      # self | own_follow | sibling_follow | wot | replied | manual | unclassified
      t.string :classification_reason, limit: 32
      # A manual Accept/Block is sticky: auto-reclassification must never
      # silently revert a decision the user made by hand.
      t.boolean :classification_locked, null: false, default: false
      t.datetime :classified_at

      # Denormalised "we have replied here", so the Known rule is a column read
      # rather than a query per conversation.
      t.boolean :has_replied, null: false, default: false

      t.datetime :last_message_at                # from sort_at, never raw rumor time
      t.text :last_message_preview               # encrypted
      t.boolean :last_message_from_self, null: false, default: false
      t.integer :unread_count, null: false, default: 0
      t.datetime :last_read_at                   # local mirror of the NIP-RS context
      t.boolean :archived, null: false, default: false

      t.timestamps
    end

    # Index names are given explicitly: the Rails-generated names for these
    # column lists exceed MariaDB's 64-character identifier limit.
    add_index :conversations, [ :account_id, :protocol, :participants_key ],
              unique: true, name: "idx_conversations_room"
    add_index :conversations, [ :user_id, :classification, :last_message_at ],
              name: "idx_conversations_inbox"
    add_index :conversations, [ :user_id, :last_message_at ],
              name: "idx_conversations_recent"
    add_index :conversations, [ :user_id, :peer_pubkey ],
              name: "idx_conversations_peer"
  end
end
