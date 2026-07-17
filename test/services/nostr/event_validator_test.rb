# frozen_string_literal: true

require_relative "../../test_helper"

class NostrEventValidatorTest < Minitest::Test
  include NostrTestHelper

  def test_validates_id_signature_author_and_recipient
    pubkey, privkey = keypair
    recipient, = keypair
    event = signed_event(privkey: privkey, pubkey: pubkey, kind: 24_133, content: "ciphertext", tags: [["p", recipient]])

    assert Nostr::EventValidator.valid?(event, kind: 24_133, author: pubkey, recipient: recipient)

    event["content"] = "altered"
    refute Nostr::EventValidator.valid?(event, recipient: recipient)
  end

  def test_rejects_wrong_recipient
    pubkey, privkey = keypair
    recipient, = keypair
    other, = keypair
    event = signed_event(privkey: privkey, pubkey: pubkey, kind: 24_133, content: "ciphertext", tags: [["p", recipient]])

    refute Nostr::EventValidator.valid?(event, recipient: other)
  end
end
