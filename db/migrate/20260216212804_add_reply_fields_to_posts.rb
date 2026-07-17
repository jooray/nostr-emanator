class AddReplyFieldsToPosts < ActiveRecord::Migration[8.1]
  def change
    add_column :posts, :reply_to_event_id, :string
    add_column :posts, :reply_to_pubkey, :string
    add_column :posts, :root_event_id, :string
    add_column :posts, :is_reply, :boolean, default: false

    add_index :posts, :reply_to_event_id
    add_index :posts, :is_reply
  end
end
