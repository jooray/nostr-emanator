# frozen_string_literal: true

namespace :encryption do
  desc "H2: re-save Account#app_privkey and NostrAuthSession#temp_privkey/#secret " \
       "so plaintext rows written before ActiveRecord encryption was configured " \
       "become encrypted. Safe to run repeatedly (skips rows already encrypted); " \
       "run once after deploying the encryption migration/model changes."
  task encrypt_existing_data: :environment do
    total = 0

    total += encrypt_attribute!(Account, :app_privkey)
    total += encrypt_attribute!(NostrAuthSession, :temp_privkey)
    total += encrypt_attribute!(NostrAuthSession, :secret)

    puts "encryption:encrypt_existing_data — encrypted #{total} previously-plaintext value(s)."
  end

  # Re-saves +attribute+ as ciphertext for every row where it's still
  # plaintext, without going through the normal dirty-tracking/save path
  # (which, by design, treats "assign the same decrypted value back" as a
  # no-op and would silently skip every row — verified against this app's
  # Rails 8.1 / activerecord 8.1.3). Instead we compute the ciphertext with
  # the exact same encryptor/key-provider/scheme `encrypts` would use, and
  # write it with a plain UPDATE so there's no intermediate bad state.
  def encrypt_attribute!(klass, attribute)
    type = klass.type_for_attribute(attribute)
    table = klass.table_name
    column = klass.connection.quote_column_name(attribute)
    pk = klass.connection.quote_column_name(klass.primary_key)
    count = 0

    klass.unscoped.where.not(attribute => nil).find_each do |record|
      raw = record.read_attribute_before_type_cast(attribute)
      next if raw.nil? || type.encrypted?(raw)

      ciphertext = ActiveRecord::Encryption.encryptor.encrypt(
        raw, key_provider: type.key_provider, cipher_options: { deterministic: type.deterministic? }
      )

      klass.connection.execute(
        "UPDATE #{klass.quoted_table_name} SET #{column} = #{klass.connection.quote(ciphertext)} " \
        "WHERE #{pk} = #{record.id.to_i}"
      )
      count += 1
    end

    puts "  #{table}.#{attribute}: encrypted #{count} row(s)."
    count
  end
end
