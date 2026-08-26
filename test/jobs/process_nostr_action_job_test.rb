# frozen_string_literal: true

require_relative "job_test_helper"

# A kind 10000 mute list is a replaceable event: whatever we sign replaces the
# one already out there. So the job has to be certain it read the current list
# before it re-signs one — and "no relay would talk to us" must never be read as
# "this account has never muted anyone".
class ProcessNostrActionJobTest < ActiveSupport::TestCase
  include JobTestHelper

  def build_mute(account: nil, target: SecureRandom.hex(32))
    account ||= build_account
    NostrAction.create!(
      account: account,
      action_type: :mute,
      target_pubkey: target,
      status: :pending
    )
  end

  # Stubs EventFetcher#fetch_replaceable with a fixed { event:, reachable: }.
  def with_fetcher(response, &block)
    fetcher = Object.new
    fetcher.define_singleton_method(:fetch_replaceable) { |_pubkey, _kind| response }
    stub_class_method(Nostr::EventFetcher, :new, ->(*_a, **_k) { fetcher }, &block)
  end

  # The job builds the unsigned event through the same service it signs with, so
  # the stub needs both halves: a real build_unsigned_event (we assert on its
  # tags) and a canned signature.
  def with_signing(&block)
    real = Nostr::EventSignerService.new
    signer = Object.new
    signer.define_singleton_method(:build_unsigned_event) { |**kwargs| real.build_unsigned_event(**kwargs) }
    signer.define_singleton_method(:request_signature) do |_account, unsigned|
      unsigned.merge("sig" => SecureRandom.hex(64))
    end
    stub_class_method(Nostr::EventSignerService, :new, ->(*_a, **_k) { signer }, &block)
  end

  def mute_event(tags:, created_at: 1.hour.ago.to_i)
    { "kind" => 10000, "created_at" => created_at, "tags" => tags, "content" => "" }
  end

  test "mute aborts when no relay answered" do
    action = build_mute

    with_fetcher({ event: nil, reachable: 0 }) do
      ProcessNostrActionJob.new.perform(action.id)
    end

    assert action.reload.failed?
    assert_match(/Could not reach any relay/, action.error_message)
  end

  test "a first-ever mute goes through when relays answered and there is no list" do
    action = build_mute

    with_fetcher({ event: nil, reachable: 2 }) do
      with_signing do
        with_publisher({ "wss://relay.example" => :ok }) do
          ProcessNostrActionJob.new.perform(action.id)
        end
      end
    end

    assert action.reload.published?, action.error_message
    assert_equal [ [ "p", action.target_pubkey ] ], action.signed_event["tags"]
  end

  test "an existing mute list is extended, not replaced" do
    action = build_mute
    already = SecureRandom.hex(32)

    with_fetcher({ event: mute_event(tags: [ [ "p", already ] ]), reachable: 2 }) do
      with_signing do
        with_publisher({ "wss://relay.example" => :ok }) do
          ProcessNostrActionJob.new.perform(action.id)
        end
      end
    end

    assert action.reload.published?, action.error_message
    assert_equal [ [ "p", already ], [ "p", action.target_pubkey ] ], action.signed_event["tags"]
  end

  # The relays we happened to ask answered "nothing", but we have seen this
  # account's mute list before — so it exists somewhere we did not read.
  test "mute aborts when relays return nothing but a mute list is known to exist" do
    action = build_mute
    cached = mute_event(tags: [ [ "p", SecureRandom.hex(32) ] ])

    stub_class_method(InteractionsCache, :read_mute_event, ->(*_a) { cached }) do
      with_fetcher({ event: nil, reachable: 3 }) do
        ProcessNostrActionJob.new.perform(action.id)
      end
    end

    assert action.reload.failed?
    assert_match(/did not return your existing mute list/, action.error_message)
  end
end
