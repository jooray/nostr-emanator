# frozen_string_literal: true

class CreateReposts < ActiveRecord::Migration[8.0]
  def change
    create_table :reposts do |t|
      t.references :post, null: false, foreign_key: true
      t.references :account, null: false, foreign_key: true
      t.integer :status, default: 0
      t.datetime :scheduled_at
      t.datetime :published_at
      t.integer :delay_minutes
      t.json :unsigned_event
      t.json :signed_event
      t.string :event_id
      t.timestamps
    end

    add_index :reposts, [:post_id, :account_id], unique: true
    add_index :reposts, :scheduled_at
  end
end
