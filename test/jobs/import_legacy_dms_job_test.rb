# frozen_string_literal: true

require_relative "../test_helper"
require_relative "job_test_helper"

# Rebuilding kind-4 history from relays.
#
# The distinction under test is that an imported row is *history*, not a send.
# The per-message `legacy_downgrade_acked_at` belongs to the consent flow that
# publishes a message, and nothing in an import ever publishes. Held to it,
# every outbound event was rejected — and because the rejection raised out of
# the event loop, the whole run aborted. That is how an account ends up with no
# legacy history at all while every five-minute poll retries the same events.
class ImportLegacyDmsJobTest < ActiveSupport::TestCase
  include NostrTestHelper
  include JobTestHelper
  include CacheHelper

  def setup
    @account = messaging_account
    @peer = keypair.first
  end

  def test_an_outbound_legacy_message_imports_without_a_consent_acknowledgement
    outbound = kind4_event(pubkey: @account.pubkey_hex, peer: @peer)

    import_with(inbound: [], outbound: [ outbound ])

    message = Message.find_by(rumor_id: outbound["id"])
    assert message, "an outbound kind-4 event must be stored, not rejected"
    assert message.outbound?
    assert message.legacy?
    assert_nil message.legacy_downgrade_acked_at,
               "imported history carries no consent ack and must not need one"
  end

  def test_both_directions_land_in_one_run
    inbound = kind4_event(pubkey: @peer, peer: @account.pubkey_hex)
    outbound = kind4_event(pubkey: @account.pubkey_hex, peer: @peer)

    import_with(inbound: [ inbound ], outbound: [ outbound ])

    assert_equal 2, Message.where(kind: Message::LEGACY_KIND).count
  end

  # One unacceptable event must not cost the rest of the history: this used to
  # raise straight out of the loop into #perform's rescue, so nothing after it
  # was reached and the next poll began from the same place.
  def test_a_rejected_event_does_not_abort_the_rest_of_the_history
    poison = kind4_event(pubkey: @account.pubkey_hex, peer: @peer, content: "ciphertext-poison")
    good = kind4_event(pubkey: @peer, peer: @account.pubkey_hex)

    import_with(inbound: [ good ], outbound: [ poison ], poison: true)

    assert Message.find_by(rumor_id: good["id"]), "the other events must still import"
    assert_nil Message.find_by(rumor_id: poison["id"]), "the rejected event must not be stored"
  end

  private

  # Stubs the relay fetch and the signer. With `poison:`, any event whose
  # plaintext decrypts to "poison" raises exactly as a validation failure would.
  def import_with(inbound:, outbound:, poison: false)
    fetcher = Object.new
    fetcher.define_singleton_method(:fetch_events) do |filter|
      filter.key?("authors") ? outbound : inbound
    end

    rpc = Object.new
    rpc.define_singleton_method(:call) do |_method, params|
      params[1].to_s.include?("poison") ? "poison" : "decrypted text"
    end

    run = lambda do
      ImportLegacyDmsJob.perform_now(@account.id)
    end

    stub_class_method(Nostr::EventFetcher, :new, ->(**_k) { fetcher }) do
      stub_class_method(Nostr::Nip46Rpc, :open, ->(_acct, **_o, &blk) { blk.call(rpc) }) do
        with_poison_ingestor(poison, &run)
      end
    end
  end

  def with_poison_ingestor(poison, &block)
    return yield unless poison

    real = Messaging::MessageIngestor.new(@account)
    wrapper = Object.new
    wrapper.define_singleton_method(:ingest) do |parsed, **opts|
      raise ActiveRecord::RecordInvalid.new(Message.new), "Validation failed" if parsed.content == "poison"

      real.ingest(parsed, **opts)
    end

    stub_class_method(Messaging::MessageIngestor, :new, ->(_acct) { wrapper }, &block)
  end

  def kind4_event(pubkey:, peer:, content: "ciphertext", created_at: Time.current.to_i)
    {
      "id" => SecureRandom.hex(32),
      "pubkey" => pubkey,
      "created_at" => created_at,
      "kind" => Message::LEGACY_KIND,
      "content" => content,
      "tags" => [ [ "p", peer ] ]
    }
  end

  def messaging_account
    account = build_account(signer: false)
    pair = ::Nostr::Keygen.new.generate_key_pair
    account.update!(
      signer_pubkey: SecureRandom.hex(32), app_pubkey: pair.public_key.to_s,
      app_privkey: pair.private_key.to_s, messaging_enabled: true,
      dm_perms_version: Nostr::AuthService::PERMISSIONS_VERSION
    )
    account
  end
end
