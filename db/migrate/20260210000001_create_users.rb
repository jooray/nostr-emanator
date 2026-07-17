# frozen_string_literal: true

class CreateUsers < ActiveRecord::Migration[8.0]
  def change
    create_table :users do |t|
      t.string :npub, null: false, index: { unique: true }
      t.string :pubkey_hex, null: false, index: { unique: true }
      t.string :display_name
      t.string :username
      t.text :about
      t.string :picture_url
      t.json :settings, default: {}
      t.timestamps
    end
  end
end
