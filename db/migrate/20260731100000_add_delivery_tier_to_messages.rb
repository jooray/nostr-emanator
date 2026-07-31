# frozen_string_literal: true

# Which relay tier actually carried an outbound gift wrap.
#
#   inbox       - the recipient's own kind 10050. Compliant; they are listening.
#   nip65       - their NIP-65 read relays. Not designated for DMs, but it is
#                 where their client is generally connected.
#   fallback    - a popular default set. Delivery depends entirely on the
#                 recipient's client reading kind 1059 across its whole pool,
#                 which every client examined does.
#
# Stored rather than derived because a peer can publish a 10050 later, and the
# badge on an old message must keep telling the truth about how it was sent.
class AddDeliveryTierToMessages < ActiveRecord::Migration[8.1]
  def change
    add_column :messages, :delivery_tier, :string, limit: 16
  end
end
