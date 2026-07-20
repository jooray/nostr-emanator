class AddSessionVersionToUsers < ActiveRecord::Migration[8.1]
  # I2: cookie-store sessions cannot be revoked server-side — a captured cookie
  # stays valid for its full 30-day life, including after the user logs out.
  # Stamping a version into the session and bumping it on logout makes logout
  # actually end that session everywhere it was copied to.
  def change
    add_column :users, :session_version, :integer, null: false, default: 0
  end
end
