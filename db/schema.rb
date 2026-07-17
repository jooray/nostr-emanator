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

ActiveRecord::Schema[8.1].define(version: 2026_07_15_000000) do
  create_table "accounts", force: :cascade do |t|
    t.text "about"
    t.string "app_privkey"
    t.string "app_pubkey"
    t.datetime "created_at", null: false
    t.string "display_name"
    t.string "npub"
    t.text "personality"
    t.string "picture_url"
    t.string "pubkey_hex", null: false
    t.json "settings", default: {}
    t.string "signer_pubkey"
    t.string "signer_relay"
    t.datetime "updated_at", null: false
    t.integer "user_id", null: false
    t.string "username"
    t.json "write_relays", default: []
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
    t.string "secret", null: false
    t.string "session_id", null: false
    t.string "temp_privkey", null: false
    t.string "temp_pubkey", null: false
    t.datetime "updated_at", null: false
    t.index ["expires_at"], name: "index_nostr_auth_sessions_on_expires_at"
    t.index ["session_id"], name: "index_nostr_auth_sessions_on_session_id", unique: true
  end

  create_table "posts", force: :cascade do |t|
    t.integer "account_id", null: false
    t.text "content"
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
    t.integer "status", default: 0
    t.json "unsigned_event"
    t.datetime "updated_at", null: false
    t.json "version_history", default: []
    t.index ["account_id", "status"], name: "index_posts_on_account_id_and_status"
    t.index ["account_id"], name: "index_posts_on_account_id"
    t.index ["is_reply"], name: "index_posts_on_is_reply"
    t.index ["reply_to_event_id"], name: "index_posts_on_reply_to_event_id"
    t.index ["scheduled_at"], name: "index_posts_on_scheduled_at"
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
    t.integer "status", default: 0
    t.json "unsigned_event"
    t.datetime "updated_at", null: false
    t.index ["account_id"], name: "index_reposts_on_account_id"
    t.index ["post_id", "account_id"], name: "index_reposts_on_post_id_and_account_id", unique: true
    t.index ["post_id"], name: "index_reposts_on_post_id"
    t.index ["scheduled_at"], name: "index_reposts_on_scheduled_at"
  end

  create_table "users", force: :cascade do |t|
    t.text "about"
    t.datetime "created_at", null: false
    t.string "display_name"
    t.string "npub", null: false
    t.string "picture_url"
    t.string "pubkey_hex", null: false
    t.json "settings", default: {}
    t.datetime "updated_at", null: false
    t.string "username"
    t.index ["npub"], name: "index_users_on_npub", unique: true
    t.index ["pubkey_hex"], name: "index_users_on_pubkey_hex", unique: true
  end

  add_foreign_key "accounts", "users"
  add_foreign_key "api_tokens", "users"
  add_foreign_key "nostr_actions", "accounts"
  add_foreign_key "posts", "accounts"
  add_foreign_key "reposts", "accounts"
  add_foreign_key "reposts", "posts"
end
