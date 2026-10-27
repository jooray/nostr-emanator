# frozen_string_literal: true

require_relative "../../test_helper"

# The composer's @mention lookup, through the app API and the web route. Both
# run Mentions::Search: own accounts first, then people the accounts follow.
class MentionsApiTest < ActionDispatch::IntegrationTest
  include NostrTestHelper
  include ApiTestHelper
  include SessionHelper
  include CacheHelper

  setup do
    @user = create_api_user
    @nal = create_signed_account(@user, display_name: "nalgorithm", username: "nalgorithm",
                                        npub: nil)
    @nal.update!(npub: Nostr::KeyConverter.hex_to_npub(@nal.pubkey_hex))
    @main = create_signed_account(@user, display_name: "Juraj", username: "juraj")
    @main.update!(npub: Nostr::KeyConverter.hex_to_npub(@main.pubkey_hex))

    @analyst = SecureRandom.hex(32)
    @naldo = SecureRandom.hex(32)
    @stranger = SecureRandom.hex(32)
    # Both accounts follow @naldo, only one follows @analyst; nobody follows @stranger.
    InteractionsCache.write_contact_list(@main.pubkey_hex, [ @analyst, @naldo ])
    InteractionsCache.write_contact_list(@nal.pubkey_hex, [ @naldo ])
    NostrProfile.store!({
      @analyst => { display_name: "The Analyst", username: "analyst" },
      @naldo => { display_name: "Naldo", username: "naldo", nip05: "naldo@example.com" },
      @stranger => { display_name: "Nala Stranger", username: "nala" }
    })
  end

  def test_own_accounts_come_first_then_people_they_follow
    api_get "/api/v1/mentions", params: { q: "nal" }
    assert_response :success
    names = json["mentions"].map { |m| m["display_name"] }
    assert_equal [ "nalgorithm", "Naldo", "The Analyst" ], names
    first = json["mentions"].first
    assert first["own"]
    assert_equal @nal.id, first["account_id"]
    assert_equal "nostr:#{@nal.npub}", first["mention"]
    refute_includes names, "Nala Stranger", "only people the accounts follow are offered"
  end

  def test_a_bare_at_sign_lists_own_accounts_only
    api_get "/api/v1/mentions", params: { q: "" }
    assert_equal [ "nalgorithm", "Juraj" ].sort, json["mentions"].map { |m| m["display_name"] }.sort
    assert json["mentions"].all? { |m| m["own"] }
  end

  def test_npub_letters_do_not_match_a_name_query
    api_get "/api/v1/mentions", params: { q: @main.npub[5, 3] }
    refute_includes json["mentions"].map { |m| m["display_name"] }, "Juraj"
    api_get "/api/v1/mentions", params: { q: @main.npub.first(12) }
    assert_includes json["mentions"].map { |m| m["display_name"] }, "Juraj"
  end

  def test_the_web_route_returns_the_same_suggestions
    sign_in_as(@user)
    get mentions_path, params: { q: "nal" }, as: :json
    assert_response :success
    assert_equal "nalgorithm", JSON.parse(response.body)["mentions"].first["display_name"]
  end

  def test_the_api_needs_a_device_token
    get "/api/v1/mentions", params: { q: "nal" }
    assert_response :unauthorized
  end

  # A pasted key is exactly that person, followed or not.
  def test_a_pasted_npub_resolves_to_that_person
    api_get "/api/v1/mentions", params: { q: Nostr::KeyConverter.hex_to_npub(@stranger) }
    assert_equal [ @stranger ], json["mentions"].map { |m| m["pubkey"] }
    assert_equal "Nala Stranger", json["mentions"].first["display_name"]
  end

  # The recipient picker also offers people already in the inbox.
  def test_peers_adds_people_you_already_message
    participants = [ @main.pubkey_hex, @stranger ].sort
    @user.conversations.create!(account: @main, participant_pubkeys: participants, peer_pubkey: @stranger,
                                participants_key: Nostr::Nip17.participants_key(participants),
                                classification: "known", last_message_at: Time.current)

    api_get "/api/v1/mentions", params: { q: "stranger" }
    assert_empty json["mentions"]

    api_get "/api/v1/mentions", params: { q: "stranger", peers: "1" }
    assert_equal [ @stranger ], json["mentions"].map { |m| m["pubkey"] }
  end
end
