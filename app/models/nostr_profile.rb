# frozen_string_literal: true

# A kind-0 profile of someone one of our accounts follows: just what an
# @mention lookup needs. Refreshed by SyncFollowProfilesJob.
class NostrProfile < ApplicationRecord
  STALE_AFTER = 7.days

  validates :pubkey_hex, presence: true, uniqueness: true

  scope :fresh, -> { where("fetched_at > ?", STALE_AFTER.ago) }

  def npub = Nostr::KeyConverter.hex_to_npub(pubkey_hex)
  def label = display_name.presence || name.presence || npub.first(16)

  # Upserts parsed ProfileFetcher hashes, keyed by pubkey.
  def self.store!(profiles, at: Time.current)
    rows = profiles.map do |pubkey, p|
      {
        pubkey_hex: pubkey,
        name: p[:username].to_s.first(255).presence,
        display_name: p[:display_name].to_s.first(255).presence,
        nip05: p[:nip05].to_s.first(255).presence,
        picture_url: p[:picture].to_s.first(2000).presence,
        fetched_at: at, created_at: at, updated_at: at
      }
    end
    return if rows.empty?

    # MariaDB matches ON DUPLICATE KEY against any unique index and rejects
    # :unique_by; SQLite needs to be told which index the conflict is on.
    if connection.adapter_name.match?(/mysql|trilogy/i)
      upsert_all(rows)
    else
      upsert_all(rows, unique_by: :pubkey_hex)
    end
  end
end
