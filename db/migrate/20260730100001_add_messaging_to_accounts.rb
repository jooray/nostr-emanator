# frozen_string_literal: true

# NIP-17 messaging is opt-in per account, because it needs signer permissions
# (nip44_encrypt / nip44_decrypt / sign_event:13) that no account paired before
# this feature was granted. A signer cannot be queried for what it granted, so we
# record which permission set an account was paired with instead.
class AddMessagingToAccounts < ActiveRecord::Migration[8.1]
  def change
    # A real column rather than a key in `settings`: the recurring schedule gates
    # the DM supervisor on this, and JSON predicates differ between SQLite
    # (development) and MariaDB (production).
    add_column :accounts, :messaging_enabled, :boolean, null: false, default: false

    # nil means "paired before DM permissions existed" -> needs a re-pair.
    add_column :accounts, :dm_perms_version, :integer

    add_index :accounts, :messaging_enabled
  end
end
