# frozen_string_literal: true

require "test_helper"

# Guards a bug class that is invisible in development and fatal in production.
#
# MariaDB has no native JSON type: `t.json` produces LONGTEXT plus a
# `json_valid()` CHECK constraint, and ActiveRecord types the column as Text. A
# Hash assigned to it is then stored as Ruby's inspect form (`{"a"=>1}`), the
# CHECK rejects it, and the insert raises — while SQLite, which development and
# this suite use, casts it happily either way.
#
# The fix is the codebase's existing convention: declare `attribute :name, :json`
# on the model. This test asserts every json column actually carries that
# declaration, so a new one cannot be added without it.
class JsonAttributeCastingTest < ActiveSupport::TestCase
  # Model => columns that must round-trip as JSON.
  JSON_ATTRIBUTES = {
    Account => %w[settings write_relays read_relays],
    User => %w[settings],
    Post => %w[publish_results signed_event unsigned_event version_history],
    Repost => %w[publish_results signed_event unsigned_event],
    NostrAction => %w[publish_results signed_event unsigned_event],
    Conversation => %w[participant_pubkeys],
    Message => %w[publish_results],
    GiftWrap => %w[relays wrap_event],
    DmRelayList => %w[relays raw_event]
  }.freeze

  JSON_ATTRIBUTES.each do |model, attributes|
    attributes.each do |attribute|
      define_method(:"test_#{model.name.underscore}_casts_#{attribute}_as_json") do
        type = model.type_for_attribute(attribute)

        assert_kind_of ActiveRecord::Type::Json, type,
          "#{model}##{attribute} is typed #{type.class}. On MariaDB that stores a Hash as " \
          "its Ruby inspect form and the json_valid CHECK constraint rejects the write. " \
          "Add `attribute :#{attribute}, :json` to #{model}."
      end
    end
  end

  # A hash must survive the round trip as a hash, not as a string.
  def test_a_hash_round_trips_through_a_declared_json_column
    account = build_account
    wrap = account.gift_wraps.create!(
      wrap_id: SecureRandom.hex(32), seen_at: Time.current, wrap_created_at: Time.current,
      wrap_event: { "id" => "abc", "tags" => [ [ "p", "x" ] ] }
    )

    assert_equal({ "id" => "abc", "tags" => [ [ "p", "x" ] ] }, wrap.reload.wrap_event)
  end

  private

  def build_account
    pubkey = SecureRandom.hex(32)
    user = User.create!(pubkey_hex: pubkey, npub: Nostr::KeyConverter.hex_to_npub(pubkey))
    user.accounts.create!(pubkey_hex: SecureRandom.hex(32), npub: "npub_json_test")
  end
end
