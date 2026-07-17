# frozen_string_literal: true

require_relative "../../test_helper"

class NostrNip46ListenerTest < ActiveSupport::TestCase
  include NostrTestHelper

  Session = Data.define(:relay_urls, :temp_pubkey, :temp_privkey, :secret, :expires_at)

  class StuckListener < Nostr::Nip46Listener
    attr_reader :relay_threads

    private

    def listen_on_relay(*)
      (@relay_threads ||= []) << Thread.current
      sleep 10
    end
  end

  def test_parent_enforces_deadline_and_stops_relay_threads
    pubkey, privkey = keypair
    auth_session = Session.new([ "wss://one.example", "wss://two.example" ], pubkey, privkey, "secret", 0.05.seconds.from_now)
    listener = StuckListener.new(auth_session)
    started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    assert_nil listener.listen_for_connect
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at

    assert_operator elapsed, :<, 1
    assert listener.relay_threads.none?(&:alive?)
  end
end
