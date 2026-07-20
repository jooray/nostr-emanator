# frozen_string_literal: true

# M13: NostrActionsController#create dedupes via find-then-create with no DB
# constraint — a double-click (or two near-simultaneous requests, e.g. an MCP
# agent retrying) can race past the app-level check and insert two rows for
# the same (account, action_type, target_event_id, target_pubkey), producing
# two distinct kind-7 reactions or two competing kind-3/kind-10000 list
# replacements. This is exactly the natural key the controller already
# dedupes on (see NostrAction.reactions_for_event / follows_for_pubkey /
# mutes_for_pubkey), so enforce it at the DB level to close the race.
#
# This intentionally does NOT exclude `failed` rows — SQLite (dev) and
# MariaDB (production) have no common syntax for a partial/filtered unique
# index, so a scoped index isn't portable here. Instead the controller
# resurrects a failed row for retry (reset to `pending` + re-enqueue) rather
# than inserting a fresh one on RecordNotUnique, so exactly one row occupies
# a given natural key for its whole lifetime — which matches the existing
# app-level behavior of treating any non-failed match as "already done".
class AddUniqueIndexToNostrActionsNaturalKey < ActiveRecord::Migration[8.1]
  def change
    add_index :nostr_actions,
      [ :account_id, :action_type, :target_event_id, :target_pubkey ],
      unique: true,
      name: "index_nostr_actions_on_natural_key"
  end
end
