# frozen_string_literal: true

# Log a user in through the real NIP-07 flow for integration tests.
#
# There is no way to fake this by poking the session: ApplicationController#
# current_user checks session[:session_version] against the user's, so the
# challenge/callback round-trip is the only way in.
module SessionHelper
  def create_signed_in_user(**attrs)
    user = create_nostr_user(**attrs)
    sign_in_as(user)
    user
  end

  def create_nostr_user(**attrs)
    pubkey = keypair.first
    User.create!(
      { pubkey_hex: pubkey, npub: Nostr::KeyConverter.hex_to_npub(pubkey), display_name: "Tester" }.merge(attrs)
    )
  end

  # Rewrites the user's keypair, because the callback has to verify a signature
  # made with the matching private key.
  def sign_in_as(user)
    pubkey, privkey = keypair
    user.update!(pubkey_hex: pubkey, npub: Nostr::KeyConverter.hex_to_npub(pubkey))

    get nostr_login_path
    challenge = response.body.match(/data-nostr-login-challenge="([0-9a-f]+)"/)[1]
    event = signed_event(
      privkey: privkey,
      pubkey: pubkey,
      kind: 22_242,
      content: "Sign in to Emanator",
      tags: [ [ "challenge", challenge ], [ "domain", login_domain ] ]
    )

    post auth_nostr_callback_path, params: { pubkey: pubkey, signed_event: event.to_json }
    follow_redirect!
    user
  end

  def login_domain
    URI.parse(Rails.application.config_for(:emanator).dig(:app, :canonical_url)).host
  end
end
