# frozen_string_literal: true

# L14: add the composite index the enqueue-scheduled-posts query actually
# needs (status, scheduled_at), an index on posts.event_id (used to enrich
# interactions by looking up posts by event id), and NOT NULL on
# posts.content/status columns that the models already require to be
# present but the schema didn't enforce.
#
# Defensively backfills any NULLs first — belt-and-suspenders in case a
# console/import script (e.g. migrate_sqlite.rake) ever wrote one — before
# tightening the constraint, and uses `change_column_null`, which Rails
# implements as a portable `UPDATE ... SET NOT NULL`/`MODIFY` on both SQLite
# and MariaDB.
class AddPostRepostIndexesAndConstraints < ActiveRecord::Migration[8.1]
  def up
    # Raw SQL rather than the Post/Repost models — migrations shouldn't
    # depend on application-model behavior (callbacks/validations) that may
    # not match this historical schema shape on a future replay.
    execute "UPDATE posts SET content = '' WHERE content IS NULL"
    execute "UPDATE posts SET status = 0 WHERE status IS NULL"
    execute "UPDATE reposts SET status = 0 WHERE status IS NULL"

    change_column_null :posts, :content, false
    change_column_null :posts, :status, false
    change_column_null :reposts, :status, false

    add_index :posts, [ :status, :scheduled_at ]
    add_index :posts, :event_id
    add_index :reposts, [ :status, :scheduled_at ]
  end

  def down
    remove_index :reposts, [ :status, :scheduled_at ]
    remove_index :posts, :event_id
    remove_index :posts, [ :status, :scheduled_at ]

    change_column_null :reposts, :status, true
    change_column_null :posts, :status, true
    change_column_null :posts, :content, true
  end
end
