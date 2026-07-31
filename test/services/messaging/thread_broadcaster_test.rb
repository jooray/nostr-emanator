# frozen_string_literal: true

require_relative "../../test_helper"
require_relative "../../jobs/job_test_helper"

class MessagingThreadBroadcasterTest < ActiveSupport::TestCase
  include NostrTestHelper
  include JobTestHelper
  include ActionCable::TestHelper

  def setup
    @account = build_account
    @peer = keypair.first
    @conversation = @account.conversations.create!(
      user: @account.user,
      participants_key: SecureRandom.hex(32),
      participant_pubkeys: [ @account.pubkey_hex, @peer ],
      peer_pubkey: @peer
    )
  end

  # THE plaintext regression guard. The cable adapter is Solid Cable, which
  # persists every broadcast payload to the cable database for a day — so a
  # broadcast carrying rendered message bubbles would store decrypted DM bodies
  # in plaintext right beside the `encrypts`-protected messages table. Only a
  # bare refresh signal may ever go over this stream; the watching page
  # re-fetches the thread with its own session instead.
  def test_broadcasts_a_bare_refresh_signal_never_message_content
    @conversation.messages.create!(
      account: @account, user: @account.user,
      rumor_id: SecureRandom.hex(32), sender_pubkey: @peer,
      direction: "inbound", status: "received", sort_at: Time.current,
      rumor_created_at: Time.current, content: "super secret plaintext"
    )
    # For a single model streamable, Turbo's internal stream name is its GID.
    stream = @conversation.to_gid_param

    assert_broadcasts(stream, 1) { Messaging::ThreadBroadcaster.refresh(@conversation) }

    payload = broadcasts(stream).last.to_s
    assert_includes payload, "refresh"
    refute_includes payload, "super secret plaintext",
                    "decrypted message content must never travel over the cable"
  end

  # The message is already saved when this runs; a cable hiccup is only the view.
  def test_a_broadcast_failure_never_raises
    stub_class_method(Turbo::StreamsChannel, :broadcast_refresh_to, ->(*) { raise IOError, "socket gone" }) do
      assert_nothing_raised { Messaging::ThreadBroadcaster.refresh(@conversation) }
    end
  end
end
