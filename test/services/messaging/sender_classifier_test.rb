# frozen_string_literal: true

require_relative "../../test_helper"
require_relative "../../jobs/job_test_helper"

class MessagingSenderClassifierTest < ActiveSupport::TestCase
  include JobTestHelper
  # Every rule here except the WoT hop reads InteractionsCache, which is inert
  # under the test environment's :null_store.
  include CacheHelper

  def setup
    @account = build_account
    @user = @account.user
    @stranger = SecureRandom.hex(32)
  end

  # --- rules that reach the main inbox ----------------------------------------

  def test_a_sender_the_receiving_account_follows_is_known
    follows(@account.pubkey_hex, @stranger)

    assert_classified "known", "own_follow"
  end

  # The product rule: people keep one main account that does the following and
  # manage others from it, so a follow by ANY sibling account under the same
  # Emanator login is reason enough to trust the sender everywhere.
  def test_a_sender_a_sibling_account_follows_is_known_under_every_account
    sibling = @user.accounts.create!(pubkey_hex: SecureRandom.hex(32), npub: "npub_sib")
    follows(sibling.pubkey_hex, @stranger)

    assert_classified "known", "sibling_follow"
  end

  def test_the_login_identitys_follows_also_count_as_a_sibling
    follows(@user.pubkey_hex, @stranger)

    assert_classified "known", "sibling_follow"
  end

  # A follow by an unrelated user's account must not leak across logins.
  def test_another_users_follows_do_not_count
    other_account = build_account
    follows(other_account.pubkey_hex, @stranger)

    assert_classified "request", "unclassified"
  end

  # Having written in a thread is a stronger signal than any follow graph.
  def test_a_conversation_we_have_replied_in_is_known
    conversation = build_conversation(has_replied: true)

    result = classify(conversation)
    assert_equal "known", result.classification
    assert_equal "replied", result.reason
  end

  def test_a_message_from_one_of_our_own_accounts_is_known
    sibling = @user.accounts.create!(pubkey_hex: SecureRandom.hex(32), npub: "npub_sib2")

    result = classify(build_conversation(participants: [ @account.pubkey_hex, sibling.pubkey_hex ]))
    assert_equal "known", result.classification
    assert_equal "self", result.reason
  end

  def test_a_note_to_self_thread_is_known
    result = classify(build_conversation(participants: [ @account.pubkey_hex ]))

    assert_equal "known", result.classification
  end

  # --- mute overrides everything ----------------------------------------------

  def test_a_muted_sender_is_hidden_even_when_followed
    follows(@account.pubkey_hex, @stranger)
    InteractionsCache.write_muted_pubkeys(@user, [ @stranger ])

    assert_classified "muted", "manual"
  end

  def test_a_muted_sender_is_hidden_even_in_a_thread_we_replied_to
    InteractionsCache.write_muted_pubkeys(@user, [ @stranger ])

    result = classify(build_conversation(has_replied: true))
    assert_equal "muted", result.classification
  end

  # --- one-hop web of trust ----------------------------------------------------

  def test_a_stranger_followed_by_someone_we_follow_is_known_via_wot
    friend = SecureRandom.hex(32)
    follows(@account.pubkey_hex, friend)

    with_wot_hits([ { "pubkey" => friend, "id" => SecureRandom.hex(32) } ]) do
      result = classify(build_conversation, wot: true)
      assert_equal "known", result.classification
      assert_equal "wot", result.reason
    end
  end

  def test_a_stranger_nobody_we_follow_follows_stays_in_requests
    follows(@account.pubkey_hex, SecureRandom.hex(32))

    with_wot_hits([]) do
      assert_equal "request", classify(build_conversation, wot: true).classification
    end
  end

  # Fail-safe: over budget, a legitimate stranger waits in Requests. The failure
  # must never be "spam reaches the main inbox".
  def test_an_exhausted_wot_budget_leaves_the_sender_in_requests
    follows(@account.pubkey_hex, SecureRandom.hex(32))
    exhaust_wot_budget

    with_wot_hits([ { "pubkey" => SecureRandom.hex(32), "id" => SecureRandom.hex(32) } ]) do
      assert_equal "request", classify(build_conversation, wot: true).classification
    end
  end

  def test_a_wot_lookup_failure_does_not_promote_the_sender
    follows(@account.pubkey_hex, SecureRandom.hex(32))

    stub_class_method(Nostr::EventFetcher, :new, ->(*_a, **_k) { raise "relays down" }) do
      assert_equal "request", classify(build_conversation, wot: true).classification
    end
  end

  # The ingest path runs with wot: false so decryption never blocks on relay I/O.
  def test_wot_is_skipped_when_disabled
    stub_class_method(Nostr::EventFetcher, :new, ->(*_a, **_k) { flunk "WoT must not run when disabled" }) do
      assert_equal "request", classify(build_conversation, wot: false).classification
    end
  end

  # --- applying the result -----------------------------------------------------

  def test_classify_writes_the_result
    follows(@account.pubkey_hex, @stranger)
    conversation = build_conversation

    assert Messaging::SenderClassifier.new(@user, wot: false).classify!(conversation)
    assert_equal "known", conversation.reload.classification
    assert_equal "own_follow", conversation.classification_reason
  end

  # An explicit user decision must survive every later automatic pass.
  def test_classify_refuses_to_touch_a_locked_conversation
    conversation = build_conversation
    conversation.block!
    follows(@account.pubkey_hex, @stranger)

    refute Messaging::SenderClassifier.new(@user, wot: false).classify!(conversation)
    assert_equal "muted", conversation.reload.classification
  end

  private

  def assert_classified(classification, reason)
    result = classify(build_conversation)
    assert_equal classification, result.classification
    assert_equal reason, result.reason
  end

  def classify(conversation, wot: false)
    Messaging::SenderClassifier.new(@user, wot: wot).classify(conversation)
  end

  def build_conversation(participants: nil, **attrs)
    participants ||= [ @account.pubkey_hex, @stranger ]
    @account.conversations.create!({
      user: @user,
      participants_key: SecureRandom.hex(32),
      participant_pubkeys: participants.map(&:downcase),
      peer_pubkey: participants.size == 2 ? participants.last : nil
    }.merge(attrs))
  end

  def follows(follower_pubkey, followed_pubkey)
    InteractionsCache.write_contact_list(follower_pubkey, [ followed_pubkey ])
  end

  def with_wot_hits(events, &block)
    fetcher = Object.new
    fetcher.define_singleton_method(:fetch_contact_lists_mentioning) { |_pubkey, authors:| events }
    stub_class_method(Nostr::EventFetcher, :new, ->(*_a, **_k) { fetcher }, &block)
  end

  def exhaust_wot_budget
    limit = Rails.application.config_for(:emanator).dig(:messaging, :wot_lookups_per_hour)
    key = "dm_wot_budget_user_#{@user.id}_#{Time.current.strftime('%Y%m%d%H')}"
    Rails.cache.write(key, limit + 10)
  end
end
