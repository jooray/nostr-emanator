class AddBunkerFlowToNostrAuthSessions < ActiveRecord::Migration[8.1]
  def change
    # Which NIP-46 handshake this row is running.
    #
    #   nostrconnect — we publish a URI, the signer initiates, and the connect
    #                  response must carry our one-time secret verbatim.
    #   bunker       — the user pastes a URI naming the signer, so WE initiate:
    #                  send `connect`, expect an "ack", then `get_public_key`.
    #
    # The two are not interchangeable. Accepting an "ack" in the nostrconnect
    # flow would defeat its exact-secret check, which is the only thing binding
    # that handshake to this browser.
    add_column :nostr_auth_sessions, :flow, :string, null: false, default: "nostrconnect"

    # The remote signer, pinned up front from the pasted bunker:// URI. Distinct
    # from `authenticated_pubkey`, which the supervisor writes on completion and
    # whose being NULL is what marks a row as still pending.
    add_column :nostr_auth_sessions, :signer_pubkey, :string

    # The supervisor's hot loop scans pending rows every second.
    add_index :nostr_auth_sessions, [:flow, :expires_at]
  end
end
