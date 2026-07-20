# frozen_string_literal: true

# H2: ActiveRecord::Encryption ciphertext (base64 JSON envelope: IV, auth
# tag, encrypted payload) is much longer than the plaintext hex it replaces
# (a 64-char privkey/secret can easily produce 300-400+ encrypted chars),
# so the old `string` columns (VARCHAR(255) on MariaDB in production) are
# too narrow. Widen to `text` on both adapters; keep existing NOT NULL
# constraints where they applied.
class WidenEncryptedColumns < ActiveRecord::Migration[8.1]
  def up
    change_column :accounts, :app_privkey, :text

    change_column :nostr_auth_sessions, :temp_privkey, :text, null: false
    change_column :nostr_auth_sessions, :secret, :text, null: false
  end

  def down
    change_column :accounts, :app_privkey, :string

    change_column :nostr_auth_sessions, :temp_privkey, :string, null: false
    change_column :nostr_auth_sessions, :secret, :string, null: false
  end
end
