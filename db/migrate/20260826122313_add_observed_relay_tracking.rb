class AddObservedRelayTracking < ActiveRecord::Migration[8.1]
  def change
    # Which relays a decoded message actually arrived on. Copied from the gift
    # wrap at ingest so it survives GiftWrap#decode! dropping the cached event,
    # and so a reply can be sent back where the peer demonstrably publishes.
    add_column :messages, :relays, :json

    # Digest of the relay set the last poll covered. When it changes — a new
    # discovery relay, a freshly published kind 10050 — the `since` watermark is
    # meaningless for the newcomers, so one deep pass is needed to pick up what
    # is already sitting there.
    add_column :dm_sync_states, :relays_digest, :string, limit: 40
  end
end
