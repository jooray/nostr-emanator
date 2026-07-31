# frozen_string_literal: true

# NIP-65 read-marked relays, which used to be parsed and thrown away.
#
# Needed for NIP-17 reception: senders that don't honour the "publish only to the
# recipient's kind 10050" MUST (0xchat, NDK and applesauce all have fallbacks that
# don't) will deliver a gift wrap to the recipient's public inbox instead. Reading
# from there costs one extra subscription and can only find more of our own
# messages, so the receive side unions this with the 10050 set.
#
# Publishing still uses write_relays only — this must never widen where we send.
class AddReadRelaysToAccounts < ActiveRecord::Migration[8.1]
  def change
    add_column :accounts, :read_relays, :json, default: []
  end
end
