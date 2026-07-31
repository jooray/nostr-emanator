# frozen_string_literal: true

# One row per account tracking inbound DM sync: the backfill cursor, decrypt
# progress for the UI, and whether the pipeline is alive.
#
# The cursor is real columns rather than a key in `settings` because concurrent
# jobs would race a JSON blob. The progress fields follow the BlossomUpload
# precedent: a human-readable `step` the UI can show, plus enough state to detect
# a job that died without finishing.
class CreateDmSyncStates < ActiveRecord::Migration[8.1]
  def change
    create_table :dm_sync_states do |t|
      t.references :account, null: false, foreign_key: true, index: { unique: true }

      # idle | backfilling | decrypting | error
      t.string :status, null: false, limit: 16, default: "idle"
      t.string :step

      t.integer :pending_wraps, null: false, default: 0
      t.integer :processed_wraps, null: false, default: 0

      # Wrapper timestamps are randomised up to two days into the past, so this is
      # only a coarse hint for `since` — wrap_id uniqueness is what makes the
      # dedupe correct.
      t.datetime :last_wrap_seen_at
      t.datetime :backfill_oldest_at
      t.datetime :backfill_completed_at
      t.datetime :last_synced_at
      t.string :last_error

      t.timestamps
    end
  end
end
