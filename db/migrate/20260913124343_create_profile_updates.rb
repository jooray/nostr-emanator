class CreateProfileUpdates < ActiveRecord::Migration[8.1]
  def change
    # Publishing a profile blocks on the user approving it in their signer (up
    # to ~120s), so it cannot happen in a web request. This row is what the
    # browser polls while the job waits — the same shape BlossomUpload uses.
    create_table :profile_updates do |t|
      t.references :account, null: false, foreign_key: true
      t.references :user, null: false, foreign_key: true
      t.string :status, null: false, default: "pending"
      t.string :step
      t.string :error
      # The edits as submitted, so a retry does not need the form again.
      t.json :edits, default: {}
      t.datetime :finished_at

      t.timestamps
    end

    # The poll endpoint looks up recent rows per account.
    add_index :profile_updates, [:account_id, :created_at]
  end
end
