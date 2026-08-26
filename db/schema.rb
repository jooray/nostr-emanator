# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.1].define(version: 2026_08_26_122313) do
  create_table "accounts", force: :cascade do |t|
    t.text "about"
    t.text "app_privkey"
    t.string "app_pubkey"
    t.datetime "created_at", null: false
    t.string "display_name"
    t.integer "dm_perms_version"
    t.boolean "messaging_enabled", default: false, null: false
    t.string "npub"
    t.text "personality"
    t.string "picture_url"
    t.string "pubkey_hex", null: false
    t.json "read_relays", default: []
    t.json "settings", default: {}
    t.string "signer_pubkey"
    t.string "signer_relay"
    t.datetime "updated_at", null: false
    t.integer "user_id", null: false
    t.string "username"
    t.json "write_relays", default: []
    t.index ["messaging_enabled"], name: "index_accounts_on_messaging_enabled"
    t.index ["user_id", "pubkey_hex"], name: "index_accounts_on_user_id_and_pubkey_hex", unique: true
    t.index ["user_id"], name: "index_accounts_on_user_id"
  end

  create_table "api_tokens", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.datetime "expires_at"
    t.datetime "last_used_at"
    t.string "name", null: false
    t.string "token_digest", null: false
    t.datetime "updated_at", null: false
    t.integer "user_id", null: false
    t.index ["token_digest"], name: "index_api_tokens_on_token_digest", unique: true
    t.index ["user_id"], name: "index_api_tokens_on_user_id"
  end

  create_table "blossom_uploads", force: :cascade do |t|
    t.integer "account_id", null: false
    t.bigint "byte_size"
    t.string "content_type"
    t.datetime "created_at", null: false
    t.string "error"
    t.string "file_path"
    t.string "filename"
    t.datetime "finished_at"
    t.string "sha256"
    t.string "status", default: "pending", null: false
    t.string "step"
    t.datetime "updated_at", null: false
    t.string "url"
    t.integer "user_id", null: false
    t.index ["account_id"], name: "index_blossom_uploads_on_account_id"
    t.index ["status", "created_at"], name: "index_blossom_uploads_on_status_and_created_at"
    t.index ["user_id", "created_at"], name: "index_blossom_uploads_on_user_id_and_created_at"
    t.index ["user_id"], name: "index_blossom_uploads_on_user_id"
  end

  create_table "conversations", force: :cascade do |t|
    t.integer "account_id", null: false
    t.boolean "archived", default: false, null: false
    t.string "classification", limit: 16, default: "request", null: false
    t.boolean "classification_locked", default: false, null: false
    t.string "classification_reason", limit: 32
    t.datetime "classified_at"
    t.datetime "created_at", null: false
    t.boolean "has_replied", default: false, null: false
    t.datetime "last_message_at"
    t.boolean "last_message_from_self", default: false, null: false
    t.text "last_message_preview"
    t.datetime "last_read_at"
    t.json "participant_pubkeys", default: [], null: false
    t.string "participants_key", limit: 64, null: false
    t.string "peer_pubkey", limit: 64
    t.string "protocol", limit: 16, default: "nip17", null: false
    t.text "subject"
    t.datetime "subject_updated_at"
    t.integer "unread_count", default: 0, null: false
    t.datetime "updated_at", null: false
    t.integer "user_id", null: false
    t.index ["account_id", "protocol", "participants_key"], name: "idx_conversations_room", unique: true
    t.index ["user_id", "classification", "last_message_at"], name: "idx_conversations_inbox"
    t.index ["user_id", "last_message_at"], name: "idx_conversations_recent"
    t.index ["user_id", "peer_pubkey"], name: "idx_conversations_peer"
  end

  create_table "dm_relay_lists", force: :cascade do |t|
    t.datetime "checked_at"
    t.datetime "created_at", null: false
    t.datetime "event_created_at"
    t.datetime "fetched_at"
    t.boolean "missing", default: false, null: false
    t.string "pubkey_hex", limit: 64, null: false
    t.json "raw_event"
    t.json "relays", default: [], null: false
    t.datetime "updated_at", null: false
    t.index ["fetched_at"], name: "index_dm_relay_lists_on_fetched_at"
    t.index ["pubkey_hex"], name: "idx_dm_relay_lists_pubkey", unique: true
  end

  create_table "dm_sync_states", force: :cascade do |t|
    t.integer "account_id", null: false
    t.datetime "backfill_completed_at"
    t.datetime "backfill_oldest_at"
    t.datetime "created_at", null: false
    t.string "last_error"
    t.datetime "last_synced_at"
    t.datetime "last_wrap_seen_at"
    t.integer "pending_wraps", default: 0, null: false
    t.integer "processed_wraps", default: 0, null: false
    t.string "relays_digest", limit: 40
    t.string "status", limit: 16, default: "idle", null: false
    t.string "step"
    t.datetime "updated_at", null: false
    t.index ["account_id"], name: "index_dm_sync_states_on_account_id", unique: true
  end

  create_table "gift_wraps", force: :cascade do |t|
    t.integer "account_id", null: false
    t.integer "attempts", default: 0, null: false
    t.datetime "created_at", null: false
    t.string "last_error"
    t.bigint "message_id"
    t.json "relays", default: [], null: false
    t.datetime "seen_at", null: false
    t.string "status", limit: 16, default: "pending", null: false
    t.datetime "updated_at", null: false
    t.datetime "wrap_created_at"
    t.json "wrap_event"
    t.string "wrap_id", limit: 64, null: false
    t.index ["account_id", "status", "wrap_created_at"], name: "idx_gift_wraps_queue"
    t.index ["account_id", "wrap_id"], name: "idx_gift_wraps_wrap", unique: true
    t.index ["status", "updated_at"], name: "idx_gift_wraps_sweep"
  end

  create_table "messages", force: :cascade do |t|
    t.integer "account_id", null: false
    t.text "content"
    t.integer "conversation_id", null: false
    t.datetime "created_at", null: false
    t.string "delivery_tier", limit: 16
    t.string "direction", limit: 3, null: false
    t.string "error"
    t.text "file_metadata"
    t.integer "kind", default: 14, null: false
    t.datetime "legacy_downgrade_acked_at"
    t.boolean "pubkey_recovered", default: false, null: false
    t.json "publish_results"
    t.string "quoted_rumor_id", limit: 64
    t.text "raw_tags"
    t.json "relays"
    t.string "reply_to_rumor_id", limit: 64
    t.datetime "rumor_created_at"
    t.string "rumor_id", limit: 64, null: false
    t.boolean "rumor_id_recomputed", default: false, null: false
    t.datetime "seal_created_at"
    t.string "sender_pubkey", limit: 64, null: false
    t.datetime "sort_at", null: false
    t.string "status", limit: 16, default: "received", null: false
    t.string "step"
    t.text "subject"
    t.datetime "updated_at", null: false
    t.integer "user_id", null: false
    t.string "wrap_id", limit: 64
    t.index ["account_id", "rumor_id"], name: "idx_messages_rumor", unique: true
    t.index ["conversation_id", "sort_at"], name: "idx_messages_thread"
    t.index ["status", "updated_at"], name: "idx_messages_sweep"
    t.index ["user_id", "direction", "sort_at"], name: "idx_messages_user_direction"
  end

  create_table "nostr_actions", force: :cascade do |t|
    t.integer "account_id", null: false
    t.integer "action_type", null: false
    t.datetime "created_at", null: false
    t.string "error_message"
    t.string "event_id"
    t.json "publish_results"
    t.json "signed_event"
    t.integer "status", default: 0
    t.string "target_event_id"
    t.integer "target_event_kind", default: 1
    t.string "target_pubkey", null: false
    t.json "unsigned_event"
    t.datetime "updated_at", null: false
    t.index ["account_id", "action_type", "status"], name: "index_nostr_actions_on_account_id_and_action_type_and_status"
    t.index ["account_id", "action_type", "target_event_id", "target_pubkey"], name: "index_nostr_actions_on_natural_key", unique: true
    t.index ["account_id", "target_event_id"], name: "index_nostr_actions_on_account_id_and_target_event_id"
    t.index ["account_id", "target_pubkey"], name: "index_nostr_actions_on_account_id_and_target_pubkey"
    t.index ["account_id"], name: "index_nostr_actions_on_account_id"
  end

  create_table "nostr_auth_sessions", force: :cascade do |t|
    t.text "auth_url"
    t.string "authenticated_pubkey"
    t.string "authenticated_user_pubkey"
    t.datetime "consumed_at"
    t.datetime "created_at", null: false
    t.datetime "expires_at", null: false
    t.datetime "listener_started_at"
    t.string "listener_token"
    t.string "pending_rpc_id"
    t.string "relay_url", null: false
    t.text "secret", null: false
    t.string "session_id", null: false
    t.text "temp_privkey", null: false
    t.string "temp_pubkey", null: false
    t.datetime "updated_at", null: false
    t.index ["expires_at"], name: "index_nostr_auth_sessions_on_expires_at"
    t.index ["session_id"], name: "index_nostr_auth_sessions_on_session_id", unique: true
  end

  create_table "posts", force: :cascade do |t|
    t.integer "account_id", null: false
    t.text "content", null: false
    t.datetime "created_at", null: false
    t.string "event_id"
    t.integer "event_kind", default: 1
    t.boolean "is_reply", default: false
    t.json "publish_results"
    t.datetime "published_at"
    t.string "reply_to_event_id"
    t.string "reply_to_pubkey"
    t.string "root_event_id"
    t.datetime "scheduled_at"
    t.json "signed_event"
    t.integer "status", default: 0, null: false
    t.json "unsigned_event"
    t.datetime "updated_at", null: false
    t.json "version_history", default: []
    t.index ["account_id", "status"], name: "index_posts_on_account_id_and_status"
    t.index ["account_id"], name: "index_posts_on_account_id"
    t.index ["event_id"], name: "index_posts_on_event_id"
    t.index ["is_reply"], name: "index_posts_on_is_reply"
    t.index ["reply_to_event_id"], name: "index_posts_on_reply_to_event_id"
    t.index ["scheduled_at"], name: "index_posts_on_scheduled_at"
    t.index ["status", "scheduled_at"], name: "index_posts_on_status_and_scheduled_at"
  end

  create_table "read_state_slots", force: :cascade do |t|
    t.integer "account_id", null: false
    t.string "client_id", limit: 64
    t.text "contexts"
    t.datetime "created_at", null: false
    t.boolean "dirty", default: false, null: false
    t.string "event_id", limit: 64
    t.datetime "last_published_at"
    t.integer "last_seen_event_created_at"
    t.boolean "own", default: false, null: false
    t.datetime "publish_after"
    t.string "slot_id", limit: 64, null: false
    t.datetime "updated_at", null: false
    t.integer "version", default: 1, null: false
    t.index ["account_id", "own"], name: "idx_read_state_slots_own"
    t.index ["account_id", "slot_id"], name: "idx_read_state_slots_slot", unique: true
    t.index ["dirty", "publish_after"], name: "idx_read_state_slots_flush"
  end

  create_table "reposts", force: :cascade do |t|
    t.integer "account_id", null: false
    t.datetime "created_at", null: false
    t.integer "delay_minutes"
    t.string "event_id"
    t.integer "post_id", null: false
    t.json "publish_results"
    t.datetime "published_at"
    t.datetime "scheduled_at"
    t.json "signed_event"
    t.integer "status", default: 0, null: false
    t.json "unsigned_event"
    t.datetime "updated_at", null: false
    t.index ["account_id"], name: "index_reposts_on_account_id"
    t.index ["post_id", "account_id"], name: "index_reposts_on_post_id_and_account_id", unique: true
    t.index ["post_id"], name: "index_reposts_on_post_id"
    t.index ["scheduled_at"], name: "index_reposts_on_scheduled_at"
    t.index ["status", "scheduled_at"], name: "index_reposts_on_status_and_scheduled_at"
  end

  create_table "users", force: :cascade do |t|
    t.text "about"
    t.datetime "created_at", null: false
    t.string "display_name"
    t.string "npub", null: false
    t.string "picture_url"
    t.string "pubkey_hex", null: false
    t.integer "session_version", default: 0, null: false
    t.json "settings", default: {}
    t.datetime "updated_at", null: false
    t.string "username"
    t.index ["npub"], name: "index_users_on_npub", unique: true
    t.index ["pubkey_hex"], name: "index_users_on_pubkey_hex", unique: true
  end

  add_foreign_key "accounts", "users"
  add_foreign_key "api_tokens", "users"
  add_foreign_key "conversations", "accounts"
  add_foreign_key "conversations", "users"
  add_foreign_key "dm_sync_states", "accounts"
  add_foreign_key "gift_wraps", "accounts"
  add_foreign_key "messages", "accounts"
  add_foreign_key "messages", "conversations"
  add_foreign_key "messages", "users"
  add_foreign_key "nostr_actions", "accounts"
  add_foreign_key "posts", "accounts"
  add_foreign_key "read_state_slots", "accounts"
  add_foreign_key "reposts", "accounts"
  add_foreign_key "reposts", "posts"
end
