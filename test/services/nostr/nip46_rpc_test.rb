# frozen_string_literal: true

require_relative "../../test_helper"
require_relative "../../jobs/job_test_helper"

# Nostr::Nip46Rpc against a real in-process relay, with a fake signer answering
# on the far side. The point of these tests is the concurrency contract:
# out-of-order responses, the in-flight cap, and per-request timeouts that don't
# take the session down with them.
class NostrNip46RpcTest < ActiveSupport::TestCase
  include NostrTestHelper
  include JobTestHelper
  include FakeRelay

  def setup
    @signer_pub, @signer_priv = keypair
    @account = build_rpc_account
  end

  # --------------------------------------------------------------- happy paths

  def test_a_single_call_returns_the_signers_result
    url = with_signer { |request| { "id" => request["id"], "result" => "pong" } }

    with_rpc(url) do |rpc|
      assert_equal "pong", rpc.call("ping", [])
    end
  end

  def test_the_request_reaches_the_signer_with_its_method_and_params
    seen = Queue.new
    url = with_signer do |request|
      seen << request
      { "id" => request["id"], "result" => "ok" }
    end

    with_rpc(url) { |rpc| rpc.call("nip44_decrypt", [ "abc", "payload" ]) }

    request = seen.pop
    assert_equal "nip44_decrypt", request["method"]
    assert_equal [ "abc", "payload" ], request["params"]
  end

  # Requests are multiplexed over one socket, so nothing may assume responses
  # come back in the order they were sent.
  def test_concurrent_requests_answered_out_of_order_each_resolve_correctly
    url = with_signer(delay_first: true) { |request| { "id" => request["id"], "result" => request["params"][0] } }

    with_rpc(url) do |rpc|
      threads = %w[one two three].map { |value| Thread.new { rpc.call("echo", [ value ]) } }
      assert_equal %w[one two three], threads.map(&:value)
    end
  end

  def test_one_socket_and_one_subscription_serve_every_request
    url = with_signer { |request| { "id" => request["id"], "result" => "ok" } }

    with_rpc(url) do |rpc|
      5.times { |i| rpc.call("echo", [ i.to_s ]) }
    end

    assert_equal 1, relay_handshakes.size, "each request must not open its own socket"
    assert_equal 1, relay_messages_of("REQ").size, "each request must not open its own subscription"
    assert_equal 5, relay_messages_of("EVENT").size
  end

  # THE production bug: a signer subscribes to whichever relays it chose, and we
  # cannot know which. Pinning one relay meant every request was published
  # successfully to a relay nobody was listening on — a 100% timeout rate with no
  # error anywhere. Requests must reach every configured relay.
  def test_a_signer_listening_on_only_one_of_several_relays_still_answers
    silent = with_relay # accepts the connection, answers nothing
    live = with_signer { |request| { "id" => request["id"], "result" => "answered" } }

    with_relays([ silent, live ]) do |rpc|
      assert_equal "answered", rpc.call("ping", [], timeout: 10)
    end
  end

  def test_a_request_is_published_to_every_relay
    first = with_signer { |request| { "id" => request["id"], "result" => "ok" } }
    second = with_relay

    with_relays([ first, second ]) do |rpc|
      rpc.call("ping", [], timeout: 10)

      # Asserted inside the session, and waited for: the answering relay resolves
      # the call immediately, and closing the session kills the other relay's
      # thread — so a bare assertion here races whichever connected second.
      assert wait_until { relay_messages_of("EVENT").size == 2 },
             "both relays should have carried the request, saw #{relay_messages_of('EVENT').size}"
      assert wait_until { relay_messages_of("REQ").size == 2 },
             "both relays should be subscribed, saw #{relay_messages_of('REQ').size}"
    end
  end

  # A relay that is simply down must not stop the others.
  def test_an_unreachable_relay_does_not_block_the_working_one
    dead = TCPServer.new("127.0.0.1", 0).then { |s| port = s.addr[1]; s.close; "ws://127.0.0.1:#{port}" }
    live = with_signer { |request| { "id" => request["id"], "result" => "still here" } }

    with_relays([ dead, live ]) do |rpc|
      assert_equal "still here", rpc.call("ping", [], timeout: 10)
    end
  end

  # ------------------------------------------------------------ in-flight cap

  # The cap is the guard against Amber's bunker-request flood crash (#169), so it
  # has to hold at the wire, not just in bookkeeping.
  def test_the_in_flight_cap_keeps_extra_requests_off_the_wire
    release = Queue.new
    url = with_relay do |socket, message|
      next unless message[0] == "EVENT"
      Thread.new do
        release.pop # hold every response until the test says so
        respond(socket, message[1]) { |request| { "id" => request["id"], "result" => "ok" } }
      end
    end

    with_rpc(url, max_in_flight: 2) do |rpc|
      callers = 4.times.map { |i| Thread.new { rpc.call("echo", [ i.to_s ]) } }

      assert wait_until { relay_messages_of("EVENT").size >= 2 }, "the first 2 requests should be sent"
      sleep 0.4
      assert_equal 2, relay_messages_of("EVENT").size,
                   "a 3rd request reached the relay while 2 were already in flight"

      4.times { release << :go }
      callers.each { |t| assert_equal "ok", t.value }
      assert_equal 4, relay_messages_of("EVENT").size
    end
  end

  # Counterpart to the test above: with a cap of 4, all 4 must reach the wire.
  # Without this, the cap assertion could pass because of some incidental
  # serialization rather than because max_in_flight is honoured.
  def test_requests_up_to_the_cap_are_all_sent_concurrently
    release = Queue.new
    url = with_relay do |socket, message|
      next unless message[0] == "EVENT"
      Thread.new do
        release.pop
        respond(socket, message[1]) { |request| { "id" => request["id"], "result" => "ok" } }
      end
    end

    with_rpc(url, max_in_flight: 4) do |rpc|
      callers = 4.times.map { |i| Thread.new { rpc.call("echo", [ i.to_s ]) } }

      assert wait_until { relay_messages_of("EVENT").size == 4 },
             "only #{relay_messages_of('EVENT').size} of 4 requests were sent under a cap of 4"

      4.times { release << :go }
      callers.each { |t| assert_equal "ok", t.value }
    end
  end

  # ----------------------------------------------------------- error handling

  def test_a_signer_error_raises_signer_error
    url = with_signer { |request| { "id" => request["id"], "error" => "user rejected" } }

    with_rpc(url) do |rpc|
      error = assert_raises(Nostr::Nip46Rpc::SignerError) { rpc.call("sign_event", [ "{}" ]) }
      assert_match(/user rejected/, error.message)
    end
  end

  def test_a_request_times_out_without_killing_the_session
    answer = false
    url = with_signer { |request| answer ? { "id" => request["id"], "result" => "late" } : nil }

    with_rpc(url) do |rpc|
      assert_raises(Nostr::Nip46Rpc::TimeoutError) { rpc.call("ping", [], timeout: 1) }

      # The session must still be usable: one stuck request cannot sink a batch.
      answer = true
      assert_equal "late", rpc.call("ping", [], timeout: 5)
    end
  end

  # An auth_url is a nudge to open a browser; the real answer follows it.
  def test_an_auth_url_does_not_resolve_the_request
    url = with_signer do |request, socket|
      reply(socket, { "id" => request["id"], "result" => "auth_url", "error" => "https://signer.example/auth" })
      { "id" => request["id"], "result" => "finally" }
    end

    with_rpc(url) do |rpc|
      assert_equal "finally", rpc.call("sign_event", [ "{}" ])
      assert_equal "https://signer.example/auth", rpc.auth_url
    end
  end

  def test_a_relay_rejecting_the_request_event_fails_it_immediately
    url = with_relay do |socket, message|
      send_text(socket, [ "OK", message[1]["id"], false, "blocked: no ephemeral events" ].to_json) if message[0] == "EVENT"
    end

    with_rpc(url) do |rpc|
      # Fails on the OK rather than waiting out the timeout — a rejected request
      # event will never reach the signer.
      error = assert_raises(Nostr::Nip46Rpc::SignerError) { rpc.call("ping", [], timeout: 20) }
      assert_match(/blocked/, error.message)
    end
  end

  # ------------------------------------------------------------- authenticity

  def test_a_response_from_another_pubkey_is_ignored
    stranger_pub, stranger_priv = keypair
    url = with_signer(as_pub: stranger_pub, as_priv: stranger_priv) do |request|
      { "id" => request["id"], "result" => "forged" }
    end

    with_rpc(url) do |rpc|
      assert_raises(Nostr::Nip46Rpc::TimeoutError) { rpc.call("ping", [], timeout: 1) }
    end
  end

  def test_a_response_for_an_unknown_request_id_is_ignored
    url = with_signer { |request| { "id" => "#{request["id"]}-not-ours", "result" => "mismatched" } }

    with_rpc(url) do |rpc|
      assert_raises(Nostr::Nip46Rpc::TimeoutError) { rpc.call("ping", [], timeout: 1) }
    end
  end

  def test_an_unpaired_account_cannot_open_a_session
    account = build_rpc_account
    account.update_columns(signer_pubkey: nil)

    assert_raises(Nostr::Nip46Rpc::NotPaired) { Nostr::Nip46Rpc.new(account).start! }
  end

  # --------------------------------------------------------------- call_many

  def test_call_many_returns_outcomes_in_input_order
    url = with_signer { |request| { "id" => request["id"], "result" => request["params"][0].upcase } }

    with_rpc(url) do |rpc|
      outcomes = rpc.call_many(%w[a b c d]) { |item| rpc.call("echo", [ item ]) }

      assert_equal %w[A B C D], outcomes.map(&:value)
      assert_equal %w[a b c d], outcomes.map(&:item)
      assert outcomes.all?(&:ok?)
    end
  end

  def test_call_many_isolates_a_failing_item
    url = with_signer do |request|
      value = request["params"][0]
      value == "bad" ? { "id" => request["id"], "error" => "nope" } : { "id" => request["id"], "result" => value }
    end

    with_rpc(url) do |rpc|
      outcomes = rpc.call_many(%w[good bad other]) { |item| rpc.call("echo", [ item ]) }

      assert_equal %w[good other], outcomes.select(&:ok?).map(&:value)
      failed = outcomes.reject(&:ok?).sole
      assert_equal "bad", failed.item
      assert_kind_of Nostr::Nip46Rpc::SignerError, failed.error
    end
  end

  def test_call_many_on_an_empty_list_does_nothing
    url = with_signer { |request| { "id" => request["id"], "result" => "ok" } }

    with_rpc(url) { |rpc| assert_equal [], rpc.call_many([]) { flunk "should not run" } }
  end

  private

  def build_rpc_account
    app_pair = ::Nostr::Keygen.new.generate_key_pair
    account = build_account(signer: false)
    account.update!(
      signer_pubkey: @signer_pub,
      app_pubkey: app_pair.public_key.to_s,
      app_privkey: app_pair.private_key.to_s
    )
    account
  end

  def with_rpc(url, **options, &block)
    with_relays([ url ], **options, &block)
  end

  def with_relays(urls, **options, &block)
    stub_class_method(Nostr::EventSignerService, :signing_relays, ->(*_a) { urls }) do
      Nostr::Nip46Rpc.open(@account, **options, &block)
    end
  end

  # Boot a relay with a fake signer behind it. The block receives the decrypted
  # JSON-RPC request (and optionally the socket) and returns the response hash,
  # or nil to stay silent.
  def with_signer(as_pub: nil, as_priv: nil, delay_first: false, &responder)
    signer_pub = as_pub || @signer_pub
    signer_priv = as_priv || @signer_priv
    first = true

    with_relay do |socket, message|
      next unless message[0] == "EVENT"

      # Answer the first request last, so callers cannot rely on FIFO ordering.
      hold = delay_first && first
      first = false
      if hold
        Thread.new { sleep 0.3; respond(socket, message[1], signer_pub, signer_priv, &responder) }
      else
        respond(socket, message[1], signer_pub, signer_priv, &responder)
      end
    end
  end

  def respond(socket, request_event, signer_pub = @signer_pub, signer_priv = @signer_priv)
    request = JSON.parse(
      Nostr::Nip44.decrypt(
        Nostr::Nip44.conversation_key(signer_priv, request_event["pubkey"]),
        request_event["content"]
      )
    )
    @reply_context = [ socket, signer_pub, signer_priv ]
    response = yield(request, socket)
    reply(socket, response, signer_pub, signer_priv) if response
  end

  def reply(socket, response, signer_pub = nil, signer_priv = nil)
    signer_pub ||= @reply_context[1]
    signer_priv ||= @reply_context[2]

    event = Nostr::Nip46Envelope.build(
      content: Nostr::Nip44.encrypt(
        Nostr::Nip44.conversation_key(signer_priv, @account.app_pubkey), JSON.generate(response)
      ),
      recipient_pubkey: @account.app_pubkey,
      sender_privkey: signer_priv,
      sender_pubkey: signer_pub
    )
    send_text(socket, [ "EVENT", relay_messages_of("REQ").first[1], event ].to_json)
  end
end
