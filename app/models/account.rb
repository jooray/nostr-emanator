# frozen_string_literal: true

class Account < ApplicationRecord
  attribute :settings, :json, default: -> { {} }
  attribute :write_relays, :json, default: -> { [] }
  # NIP-65 read-marked relays. Used for *receiving* only — see
  # AddReadRelaysToAccounts. Publishing must always use write_relays.
  attribute :read_relays, :json, default: -> { [] }

  # H2: the NIP-46 app private key is a long-lived signing-delegation
  # credential — Amber signs kind-1 notes without manual confirmation, so a
  # stolen plaintext value would mean silent, unlimited posting as this
  # account. See config/initializers/active_record_encryption.rb.
  encrypts :app_privkey

  belongs_to :user
  has_many :posts, dependent: :destroy
  has_many :reposts, dependent: :destroy
  has_many :nostr_actions, dependent: :destroy
  has_many :conversations, dependent: :destroy
  has_many :messages, dependent: :destroy
  has_many :gift_wraps, dependent: :destroy
  has_many :read_state_slots, dependent: :destroy
  has_one :dm_sync_state, dependent: :destroy

  scope :messaging, -> { where(messaging_enabled: true) }

  validates :pubkey_hex, presence: true
  validates :pubkey_hex, uniqueness: { scope: :user_id }

  # Both validations below guard a *value being set*, so they only run when that
  # value actually changes.
  #
  # Unconditionally they also block every unrelated write to a record that
  # already violates them, and these tables predate both rules. That took down
  # re-pairing in production: an account carrying a grandfathered over-long
  # personality could not reconnect its signer, because saving the new signer
  # keys re-validated the whole record. Pairing is a recovery path — it must not
  # be gated on an unrelated field being tidy.
  validate :blossom_server_must_be_safe, if: :blossom_server_setting_changed?

  # Personality text is injected verbatim into every AI prompt; unbounded text
  # would let one account blow up (and pay for) every completion.
  MAX_PERSONALITY_LENGTH = 8_000
  validates :personality, length: { maximum: MAX_PERSONALITY_LENGTH }, if: :personality_changed?

  before_validation :set_npub, on: :create

  def display_name_or_npub
    display_name.presence || username.presence || npub&.truncate(20) || pubkey_hex.truncate(16)
  end

  def has_signer?
    signer_pubkey.present? && app_privkey.present?
  end

  # Record the NIP-46 connection a pairing produced. Assigns without saving so
  # callers keep their own save/validation flow.
  #
  # One definition for all three pairing paths (login import, add account,
  # re-pair) so `dm_perms_version` can never be stamped by some of them and not
  # others — which would present as messaging silently not working.
  def apply_signer(auth_session)
    assign_attributes(
      signer_pubkey: auth_session.authenticated_pubkey,
      signer_relay: auth_session.relay_urls.first,
      app_pubkey: auth_session.temp_pubkey,
      app_privkey: auth_session.temp_privkey,
      dm_perms_version: Nostr::AuthService::PERMISSIONS_VERSION,
      # Pairing IS the opt-in: the user just approved a permission set that
      # includes message encryption and sealing, on a screen that says so. Without
      # this the inbox pipeline stays gated off and nothing ever fetches.
      messaging_enabled: true
    )
    # Re-pairing is the remedy for a signer that refused a DM operation, so a
    # fresh pairing clears the marker rather than leaving a stale warning up.
    self.settings = (settings || {}).except("dm_capability")
    self
  end

  # NIP-17 needs signer permissions (nip44_encrypt, nip44_decrypt, sign_event:13)
  # that no account paired before this feature was granted. A signer cannot be
  # asked what it granted, so we compare the permission set the account was
  # paired with — nil means "paired before DM permissions existed".
  def messaging_capable?
    has_signer? && dm_perms_version.to_i >= Nostr::AuthService::PERMISSIONS_VERSION
  end

  # The signer actively refused a DM operation, so re-pairing will not help until
  # the user changes their approval in the signer app.
  def messaging_denied? = settings&.dig("dm_capability") == "denied"

  # A relay demanded NIP-42 and the signature did not come back. Surfaced on the
  # Messages page, because the symptom is otherwise a silently empty inbox.
  def relay_auth_blocked? = settings&.dig("amber_auth_blocked_at").present?

  def mark_relay_auth_blocked!(host)
    update_settings! do |current|
      current.merge(
        "amber_auth_blocked_at" => Time.current.iso8601,
        "amber_auth_blocked_relay" => host
      )
    end
  end

  # Cleared when an authentication succeeds ON THE RELAY THE WARNING NAMES — a
  # success elsewhere proves nothing. With an Amber whitelist that contains relay
  # A but not relay B, A succeeds on every poll while B is silently rejected (and
  # its rejection is cached for hours, so it does not re-assert itself);
  # clearing on A's success would hide the warning for exactly as long as the
  # problem it describes persists.
  #
  # It must still clear on a matching success: before that, the warning was a
  # tombstone — it survived the bug that caused it being fixed, told the user to
  # change a signer setting that was already correct, and gave them no way to
  # make it go away.
  def clear_relay_auth_blocked!(host)
    update_settings! do |current|
      next current unless current["amber_auth_blocked_relay"] == host

      current.except("amber_auth_blocked_at", "amber_auth_blocked_relay")
    end
  end

  def needs_messaging_repair? = has_signer? && !messaging_capable?

  # Relays the user has chosen to publish as this account's kind-10050 DM inbox.
  #
  # Deliberately NO fallback to a configured default. Emanator does not create
  # Nostr identities — these accounts are already in use in other clients, which
  # have probably already published a 10050. The published list (cached in
  # DmRelayList) is the only truth about where this account's DMs land; inventing
  # a default here would both overrule the user and point us at the wrong relays.
  #
  # Empty therefore means "the user has not asked us to publish a list", not
  # "use ours". NIP-17 asks for a SMALL list (1-3): every sender must publish to
  # all of them.
  def dm_relay_prefs
    Array(settings&.dig("dm_relay_prefs"))
  end

  def dm_relay_prefs=(urls)
    cleaned = Array(urls).map { |u| u.to_s.strip }.reject(&:blank?)
      .select { |u| Security::UrlGuard.safe_relay?(u) }
      .uniq.first(DmRelayList::MAX_RELAYS)
    self.settings = (settings || {}).merge("dm_relay_prefs" => cleaned)
  end

  # Offered in the DM-inbox picker, never applied automatically. Each entry
  # carries whether the relay enforces NIP-42, because that decides whether third
  # parties can enumerate the account's incoming wraps.
  def self.suggested_dm_relays
    Array(Rails.application.config_for(:emanator).dig(:nostr, :suggested_dm_relays))
  end

  # Whether to import legacy NIP-04 threads for this account.
  #
  # On by default (opt-OUT, not opt-in): most Nostr identities have never
  # published a kind 10050, so they have no gift wraps at all and their entire DM
  # history is kind 4. An inbox that ignored it would be empty for most people —
  # which is exactly how this presented in production.
  def legacy_dm_import?
    setting = settings&.dig("legacy_dm_import")
    return setting if [ true, false ].include?(setting)

    Rails.application.config_for(:emanator).dig(:messaging, :legacy_dm_import) != false
  end

  # Relays to probe for someone's kind 10050 before concluding they have none.
  # Query these WITHOUT NIP-42 auth — see the config comment.
  def self.dm_indexer_relays
    Array(Rails.application.config_for(:emanator).dig(:nostr, :dm_indexer_relays))
  end

  # Blossom media server for this account, falling back to the global default.
  # Normalized to drop any trailing slash so we can append "/upload" etc.
  def blossom_server
    raw = settings&.dig("blossom_server").presence || Account.default_blossom_server
    raw.to_s.strip.sub(%r{/+\z}, "")
  end

  # Persisted via account_params (:blossom_server). Stored in the settings JSON.
  # Changing the server clears the per-server "/media unsupported" cache.
  def blossom_server=(value)
    normalized = value.to_s.strip.presence
    self.settings = (settings || {}).merge("blossom_server" => normalized)
    if settings["blossom_media_unsupported"].present? &&
       settings["blossom_media_unsupported"] != blossom_server
      settings.delete("blossom_media_unsupported")
    end
  end

  # Whether to attempt the BUD-05 /media endpoint for this account's server.
  # Defaults to true; set false (cached per-server) after a failed attempt.
  def blossom_media_supported?
    settings&.dig("blossom_media_unsupported") != blossom_server
  end

  def mark_media_unsupported!
    self.settings = (settings || {}).merge("blossom_media_unsupported" => blossom_server)
    save!
  end

  def self.default_blossom_server
    Rails.application.config_for(:emanator).dig(:blossom, :server)
  end

  private

  # Read-merge-write on the settings JSON, made safe for concurrent callers. The
  # relay-auth mark/clear above run inside the poller's one-thread-per-relay auth
  # callbacks, so two relays finishing together would otherwise each write a
  # settings hash computed from the same stale in-memory copy, silently losing
  # one write (or clobbering an unrelated key changed in between). Row-lock and
  # re-read, so every merge starts from what is actually in the database.
  def update_settings!
    ActiveRecord::Base.connection_pool.with_connection do
      transaction do
        locked = self.class.lock.find(id).settings || {}
        update_columns(settings: yield(locked))
      end
    end
  end

  # H1: the per-account Blossom server is a URL the *server* connects to (and
  # PUTs attacker-chosen bytes at), so an unvalidated value is an SSRF primitive
  # against internal hosts. Only a public https endpoint is acceptable.
  # True only when the Blossom URL itself was edited — not merely because some
  # other key in the settings JSON moved. Without this, a signer re-pair (which
  # touches settings) would re-run an SSRF check that does live DNS, so a
  # momentarily unresolvable media host could block reconnecting a signer.
  def blossom_server_setting_changed?
    return false unless settings_changed?

    (settings_was || {})["blossom_server"] != settings&.dig("blossom_server")
  end

  def blossom_server_must_be_safe
    configured = settings&.dig("blossom_server").presence
    return if configured.blank?

    Security::UrlGuard.validate!(blossom_server, schemes: Security::UrlGuard.http_schemes)
  rescue Security::UrlGuard::UnsafeUrlError => e
    errors.add(:blossom_server, e.message)
  end

  def set_npub
    if pubkey_hex.present? && npub.blank?
      self.npub = Nostr::KeyConverter.hex_to_npub(pubkey_hex)
    end
  end
end
