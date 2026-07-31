# frozen_string_literal: true

require_relative "../test_helper"
require_relative "job_test_helper"

# The acknowledged NIP-04 downgrade. It exists only for recipients who cannot
# receive NIP-17 at all — notably Damus users, since Damus still has no NIP-17
# support and therefore no kind 10050.
class SendLegacyDirectMessageJobTest < ActiveSupport::TestCase
  include NostrTestHelper
  include JobTestHelper
  include CacheHelper

  def setup
    @account = messaging_account
    @peer = keypair.first
    @conversation = @account.conversations.create!(
      user: @account.user, protocol: "nip04",
      participants_key: SecureRandom.hex(32),
      participant_pubkeys: [ @account.pubkey_hex, @peer ].map(&:downcase),
      peer_pubkey: @peer
    )
  end

  def test_a_legacy_message_is_encrypted_signed_and_published
    message = build_legacy("meet me at eight")

    published = capture_publishes { SendLegacyDirectMessageJob.perform_now(message.id) }

    assert_equal "sent", message.reload.status
    event = published.sole[:event]
    assert_equal Message::LEGACY_KIND, event["kind"]
    assert_equal @account.pubkey_hex, event["pubkey"]
    assert_includes event["tags"], [ "p", @peer ]
    # The point of the warning: the text is encrypted, the counterparty is not.
    refute_includes event["content"], "meet me at eight"
  end

  # A kind 4 has no rumor, so its real id only exists after signing. Storing it
  # is what lets an inbound copy of the same event deduplicate against this row.
  def test_the_placeholder_rumor_id_is_replaced_with_the_real_event_id
    message = build_legacy
    placeholder = message.rumor_id

    published = capture_publishes { SendLegacyDirectMessageJob.perform_now(message.id) }

    assert_not_equal placeholder, message.reload.rumor_id
    assert_equal published.sole[:event]["id"], message.rumor_id
  end

  # The inverse of the gift-wrap policy: kind-4 metadata is public by
  # construction, so there is nothing left to protect by restricting relays — and
  # the recipient's NIP-65 READ relays are where they expect to be reached.
  def test_it_publishes_to_the_recipients_read_relays_plus_our_own_with_defaults
    @account.update!(write_relays: [ "wss://mine.example" ])
    message = build_legacy

    published = capture_publishes(peer_read_relays: [ "wss://their-inbox.example" ]) do
      SendLegacyDirectMessageJob.perform_now(message.id)
    end

    relays = published.sole[:relays]
    assert_includes relays, "wss://their-inbox.example"
    assert_includes relays, "wss://mine.example"
    # Unlike a gift wrap, the ordinary relay defaults are correct here.
    refute_equal false, published.sole[:opts][:include_defaults]
  end

  # The model refuses an unacknowledged kind-4 outbound row, so the job can only
  # ever be handed a message the user consented to.
  def test_an_unacknowledged_message_cannot_even_be_created
    message = @conversation.messages.new(
      account: @account, user: @account.user, rumor_id: SecureRandom.hex(32),
      sender_pubkey: @account.pubkey_hex, kind: Message::LEGACY_KIND,
      direction: "outbound", status: "pending", sort_at: Time.current, content: "sneaky"
    )

    refute message.valid?
    assert_match(/metadata is public/, message.errors[:base].join)
  end

  def test_sending_marks_the_conversation_replied_and_known
    @conversation.update!(classification: "request")
    message = build_legacy

    capture_publishes { SendLegacyDirectMessageJob.perform_now(message.id) }

    @conversation.reload
    assert @conversation.has_replied?
    assert_equal "known", @conversation.classification
  end

  def test_no_relay_accepting_it_fails_the_message
    message = build_legacy

    capture_publishes(result: ->(relays) { relays.index_with { :error } }) do
      SendLegacyDirectMessageJob.perform_now(message.id)
    end

    assert_equal "failed", message.reload.status
    assert_match(/No relay accepted/, message.error)
  end

  def test_a_second_run_does_not_resend
    message = build_legacy
    capture_publishes { SendLegacyDirectMessageJob.perform_now(message.id) }

    published = capture_publishes { SendLegacyDirectMessageJob.perform_now(message.id) }

    assert_empty published
    assert_equal "sent", message.reload.status
  end

  private

  def messaging_account
    _pubkey, @account_privkey = pending_keypair
    account = build_account(signer: false)
    pair = ::Nostr::Keygen.new.generate_key_pair
    account.update!(
      signer_pubkey: SecureRandom.hex(32), app_pubkey: pair.public_key.to_s,
      app_privkey: pair.private_key.to_s, messaging_enabled: true,
      dm_perms_version: Nostr::AuthService::PERMISSIONS_VERSION
    )
    account
  end

  def build_legacy(content = "old school")
    Messaging::OutboundBuilder.new(@conversation).build(content: content, legacy_ack: true).message
  end

  # Signer stand-in. NIP-04 encryption happens in the signer, which is why there
  # is deliberately no local NIP-04 encryption in this codebase.
  def with_signer(&block)
    privkey = @account_privkey
    rpc = Object.new
    rpc.define_singleton_method(:call) do |method, params|
      case method
      when "nip04_encrypt" then "#{Base64.strict_encode64("enc:#{params[1]}")}?iv=#{Base64.strict_encode64('iv')}"
      when "sign_event"
        event = JSON.parse(params[0])
        event["id"] = Nostr::EventValidator.event_id(event)
        event["sig"] = Schnorr.sign([ event["id"] ].pack("H*"), [ privkey ].pack("H*")).encode.unpack1("H*")
        JSON.generate(event)
      else raise "unexpected method #{method}"
      end
    end

    stub_class_method(Nostr::Nip46Rpc, :open, ->(*_a, **_k, &blk) { blk.call(rpc) }, &block)
  end

  def capture_publishes(peer_read_relays: [ "wss://their-inbox.example" ], result: nil, &block)
    calls = []
    publisher = Object.new
    publisher.define_singleton_method(:publish) do |event, relays:, **opts|
      calls << { event: event, relays: relays, opts: opts }
      result ? result.call(relays) : relays.index_with { :ok }
    end

    fetcher = Object.new
    fetcher.define_singleton_method(:fetch_relay_list) { |_pubkey| { write: [], read: peer_read_relays } }

    stub_class_method(Nostr::EventPublisherService, :new, ->(*_a, **_k) { publisher }) do
      stub_class_method(Nostr::RelayListFetcher, :new, ->(*_a) { fetcher }) do
        with_signer(&block)
      end
    end
    calls
  end
end
