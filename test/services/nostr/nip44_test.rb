# frozen_string_literal: true

require_relative "../../test_helper"

class NostrNip44Test < Minitest::Test
  VECTOR_KEY = "c41c775356fd92eadc63ff5a0dc1da211b268cbea22316767095b2871ea1412d"
  VECTOR_NONCE = "0000000000000000000000000000000000000000000000000000000000000001"
  VECTOR_PAYLOAD = "AgAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAABee0G5VSK0/9YypIObAtDKfYEAjD35uVkHyB0F4DwrcNaCXlCWZKaArsGrY6M9wnuTMxWfp1RTN9Xga8no+kF5Vsb"

  def test_official_encryption_vector
    payload = Nostr::Nip44.encrypt([VECTOR_KEY].pack("H*"), "a", nonce: [VECTOR_NONCE].pack("H*"))

    assert_equal VECTOR_PAYLOAD, payload
    assert_equal "a", Nostr::Nip44.decrypt([VECTOR_KEY].pack("H*"), payload)
  end

  def test_rejects_tampered_payload
    payload = Base64.strict_decode64(VECTOR_PAYLOAD)
    payload.setbyte(40, payload.getbyte(40) ^ 1)

    assert_raises(Nostr::Nip44::DecryptionError) do
      Nostr::Nip44.decrypt([VECTOR_KEY].pack("H*"), Base64.strict_encode64(payload))
    end
  end
end
