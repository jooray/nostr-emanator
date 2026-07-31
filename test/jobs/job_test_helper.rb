# frozen_string_literal: true

require_relative "../test_helper"

# Shared record factories + stubs for the post/repost job tests.
module JobTestHelper
  def build_account(signer: true)
    n = SecureRandom.hex(4)
    user = User.create!(
      npub: "npub_test_#{n}",
      pubkey_hex: SecureRandom.hex(32)
    )
    user.accounts.create!(
      pubkey_hex: take_keypair.first,
      npub: "npub_acct_#{n}",
      display_name: "Account #{n}",
      signer_pubkey: signer ? SecureRandom.hex(32) : nil,
      app_privkey: signer ? SecureRandom.hex(32) : nil,
      write_relays: ["wss://relay.example"]
    )
  end

  def build_post(account: nil, status: :awaiting_signature, scheduled_at: 1.hour.from_now, **attrs)
    account ||= build_account
    account.posts.create!(
      content: "hello world",
      event_kind: 1,
      status: status,
      scheduled_at: scheduled_at,
      **attrs
    )
  end

  def build_repost(post:, account: nil, status: :awaiting_signature, scheduled_at: 2.hours.from_now, **attrs)
    account ||= build_account
    post.reposts.create!(
      account: account,
      status: status,
      scheduled_at: scheduled_at,
      delay_minutes: 30,
      **attrs
    )
  end

  # M4: the publish jobs re-verify the stored signature against the account's
  # pubkey, so test events have to be real. `fake_event` mints the keypair that
  # the *next* build_account will use, which makes the usual
  # `build_post(signed_event: fake_event)` produce a post whose event genuinely
  # is signed by its own account's key.
  def pending_keypair
    @pending_keypair ||= begin
      pair = ::Nostr::Keygen.new.generate_key_pair
      [pair.public_key.to_s, pair.private_key.to_s]
    end
  end

  def take_keypair
    keys = pending_keypair
    @pending_keypair = nil
    keys
  end

  def fake_event(kind: 1, content: "hello world", created_at: Time.now.to_i)
    pubkey, privkey = pending_keypair
    event = {
      "pubkey" => pubkey,
      "created_at" => created_at,
      "kind" => kind,
      "tags" => [],
      "content" => content
    }
    event["id"] = Nostr::EventValidator.event_id(event)
    event["sig"] = Schnorr.sign([event["id"]].pack("H*"), [privkey].pack("H*")).encode.unpack1("H*")
    event
  end

  # An event that is well-formed but signed by someone else's key.
  def foreign_event
    pair = ::Nostr::Keygen.new.generate_key_pair
    pubkey = pair.public_key.to_s
    privkey = pair.private_key.to_s
    event = { "pubkey" => pubkey, "created_at" => Time.now.to_i, "kind" => 1, "tags" => [], "content" => "not yours" }
    event["id"] = Nostr::EventValidator.event_id(event)
    event["sig"] = Schnorr.sign([event["id"]].pack("H*"), [privkey].pack("H*")).encode.unpack1("H*")
    event
  end

  # Minitest 6 no longer ships Object#stub, so swap the singleton method.
  def stub_class_method(klass, name, impl)
    singleton = klass.singleton_class
    original = klass.method(name)
    singleton.send(:define_method, name) { |*args, **kwargs, &blk| impl.call(*args, **kwargs, &blk) }
    yield
  ensure
    singleton.send(:define_method, name) { |*args, **kwargs, &blk| original.call(*args, **kwargs, &blk) }
  end

  # Turbo broadcasts render partials that need a full view context; the jobs
  # only use them for progress UI, so they are stubbed out.
  def without_broadcasts(&block)
    stub_class_method(Turbo::StreamsChannel, :broadcast_replace_to, ->(*_a, **_k) { nil }, &block)
  end

  # Stubs Nostr::EventSignerService#request_signature with `response`
  # (a value, or a callable taking (account, unsigned_event)).
  def with_signer(response, &block)
    signer = Object.new
    signer.define_singleton_method(:request_signature) do |account, unsigned|
      response.respond_to?(:call) ? response.call(account, unsigned) : response
    end
    stub_class_method(Nostr::EventSignerService, :new, ->(*_a, **_k) { signer }, &block)
  end

  # `**opts` so adding a keyword to EventPublisherService#publish (e.g.
  # include_defaults:) does not make every publish-job test raise ArgumentError.
  # `results` may be a callable taking (relays) or (relays, opts).
  def with_publisher(results, &block)
    publisher = Object.new
    publisher.define_singleton_method(:publish) do |_event, relays:, **opts|
      next results unless results.respond_to?(:call)

      results.arity == 1 ? results.call(relays) : results.call(relays, opts)
    end
    stub_class_method(Nostr::EventPublisherService, :new, ->(*_a, **_k) { publisher }, &block)
  end
end
