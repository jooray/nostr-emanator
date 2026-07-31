# frozen_string_literal: true

# Records that the user was told a message would be sent as a legacy NIP-04 DM,
# and chose to anyway.
#
# Kind 4 puts the sender pubkey, the recipient pubkey and the timestamp in the
# clear on every relay it touches — the social graph, publicly. It is also
# unauthenticated AES-256-CBC (no MAC), so the ciphertext is malleable. We only
# ever send it when the recipient has published no kind 10050 and therefore
# cannot receive a NIP-17 message at all (notably: Damus has no NIP-17 support
# yet, so its users are in exactly this position).
#
# Storing the acknowledgement rather than trusting the UI means the downgrade
# cannot happen through a code path that forgot to ask, and the message bubble can
# stay permanently marked as legacy instead of relying on a transient warning.
class AddLegacyDowngradeToMessages < ActiveRecord::Migration[8.1]
  def change
    add_column :messages, :legacy_downgrade_acked_at, :datetime
  end
end
