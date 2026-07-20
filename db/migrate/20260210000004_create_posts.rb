# frozen_string_literal: true

class CreatePosts < ActiveRecord::Migration[8.0]
  def change
    create_table :posts do |t|
      t.references :account, null: false, foreign_key: true
      t.text :content
      t.integer :status, default: 0
      t.datetime :scheduled_at
      t.datetime :published_at
      t.integer :event_kind, default: 1
      t.json :unsigned_event
      t.json :signed_event
      t.string :event_id
      t.json :version_history, default: []
      t.timestamps
    end

    add_index :posts, [:account_id, :status]
    add_index :posts, :scheduled_at
  end
end
