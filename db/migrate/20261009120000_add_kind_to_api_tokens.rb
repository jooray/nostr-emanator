# frozen_string_literal: true

# Device tokens for the native app sit beside the MCP tokens in the same table,
# told apart by `kind`. Additive only: every existing row is an MCP token, which
# is exactly what the default says.
class AddKindToApiTokens < ActiveRecord::Migration[8.1]
  def change
    add_column :api_tokens, :kind, :string, null: false, default: "mcp"
    add_column :api_tokens, :client_version, :string
    add_index :api_tokens, [ :user_id, :kind ]
  end
end
