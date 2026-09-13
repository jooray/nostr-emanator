# frozen_string_literal: true

# H2: keys for ActiveRecord::Encryption, backing `encrypts :app_privkey` on
# Account and `encrypts :temp_privkey, :secret` on NostrAuthSession — the
# NIP-46 signing-delegation credential and session secrets used to be plain
# columns (see db/schema.rb).
#
# Preferred source: Rails encrypted credentials —
#   bin/rails credentials:edit
#     active_record_encryption:
#       primary_key: ...
#       deterministic_key: ...
#       key_derivation_salt: ...
#
# Fallback: plain environment variables, since production loads its secrets
# from ~/apps/nostr-emanator/.env via systemd's EnvironmentFile rather than
# config/master.key (see CLAUDE.md "Production Deployment" / ".env" API-key
# pattern already used for VENICE_API_KEY etc.):
#   ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY
#   ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY
#   ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT
#
# Generate a set of keys with:
#   ruby -rsecurerandom -e '3.times { puts SecureRandom.alphanumeric(32) }'
ar_encryption_credentials = Rails.application.credentials.active_record_encryption || {}

# Last-resort source: derived from secret_key_base. Without it, an environment
# that is missing the three variables above runs with nil keys, and then every
# write to an encrypted attribute raises — which for `nostr_auth_sessions` means
# a total login outage with no obvious cause. secret_key_base is already
# mandatory in production, so a derived key is always available. These are real
# keys (HKDF via KeyGenerator), not placeholders; the only thing they give up is
# rotation independent of secret_key_base, which is why the explicit sources win.
derived = lambda do |purpose|
  ActiveSupport::KeyGenerator
    .new(Rails.application.secret_key_base, hash_digest_class: OpenSSL::Digest::SHA256)
    .generate_key("emanator/active_record_encryption/#{purpose}", 32)
    .unpack1("H*")
end

Rails.application.config.active_record.encryption.primary_key =
  ar_encryption_credentials[:primary_key].presence ||
  ENV["ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY"].presence ||
  derived.call("primary_key")
Rails.application.config.active_record.encryption.deterministic_key =
  ar_encryption_credentials[:deterministic_key].presence ||
  ENV["ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY"].presence ||
  derived.call("deterministic_key")
Rails.application.config.active_record.encryption.key_derivation_salt =
  ar_encryption_credentials[:key_derivation_salt].presence ||
  ENV["ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT"].presence ||
  derived.call("key_derivation_salt")

# Rows written before this initializer existed (production `accounts.app_privkey`,
# `nostr_auth_sessions.temp_privkey`/`secret`) are plaintext. This lets the app
# keep reading them; `bin/rails encryption:encrypt_existing_data`
# (lib/tasks/encryption.rake) re-saves each one as ciphertext. Left on
# permanently as a safety net for any row the task might ever miss — it only
# affects attributes that fail to decrypt as ciphertext, so it never weakens
# already-encrypted data.
Rails.application.config.active_record.encryption.support_unencrypted_data = true
