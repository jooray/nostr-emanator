# frozen_string_literal: true

# C6/M5: Blossom uploads no longer run inside the web request. The controller
# stages the bytes on disk, creates one of these rows and enqueues
# BlossomUploadJob; the browser polls the row until it reaches completed/failed.
class CreateBlossomUploads < ActiveRecord::Migration[8.1]
  def change
    create_table :blossom_uploads do |t|
      # No FK constraints on purpose: these rows are short-lived scratch state
      # (swept after BlossomUpload::RETENTION) and must never block deleting an
      # account or a user that happens to have an upload in flight.
      t.references :user, null: false, foreign_key: false
      t.references :account, null: false, foreign_key: false

      t.string :status, null: false, default: "pending"
      t.string :step
      t.string :filename
      t.string :content_type
      t.bigint :byte_size
      t.string :sha256
      t.string :url
      t.string :error
      t.string :file_path
      t.datetime :finished_at

      t.timestamps
    end

    add_index :blossom_uploads, [ :user_id, :created_at ]
    add_index :blossom_uploads, [ :status, :created_at ]
  end
end
