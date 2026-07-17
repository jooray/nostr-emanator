# frozen_string_literal: true

class HardenNostrAuthSessions < ActiveRecord::Migration[8.1]
  def change
    add_column :nostr_auth_sessions, :auth_url, :text
    add_column :nostr_auth_sessions, :pending_rpc_id, :string
    add_column :nostr_auth_sessions, :listener_started_at, :datetime
    add_column :nostr_auth_sessions, :listener_token, :string
    add_column :nostr_auth_sessions, :consumed_at, :datetime
  end
end
