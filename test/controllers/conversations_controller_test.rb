# frozen_string_literal: true

require_relative "../test_helper"

class ConversationsControllerTest < ActionDispatch::IntegrationTest
  include NostrTestHelper
  include SessionHelper
  include CacheHelper

  def setup
    @user = create_signed_in_user
    @account = paired_account("Main")
    @peer = SecureRandom.hex(32)
  end

  def test_the_inbox_shows_known_conversations
    known = conversation(classification: "known", preview: "from a friend")
    conversation(classification: "request", preview: "from a stranger")

    get messages_path

    assert_response :success
    assert_match(/from a friend/, response.body)
    refute_match(/from a stranger/, response.body)
    assert_equal known, assigns_conversations.sole
  end

  def test_the_requests_tab_shows_only_unvouched_conversations
    conversation(classification: "known", preview: "from a friend")
    conversation(classification: "request", preview: "from a stranger")

    get messages_path(tab: "requests")

    assert_response :success
    assert_match(/from a stranger/, response.body)
    refute_match(/from a friend/, response.body)
  end

  def test_muted_conversations_appear_in_neither_tab
    conversation(classification: "muted", preview: "spam text")

    get messages_path
    refute_match(/spam text/, response.body)

    get messages_path(tab: "requests")
    refute_match(/spam text/, response.body)
  end

  # The whole point of the tab is one inbox across identities, so the filter has
  # to be real rather than cosmetic.
  def test_the_account_filter_narrows_the_list_and_persists
    other = paired_account("Second")
    conversation(account: @account, classification: "known", preview: "for main")
    conversation(account: other, classification: "known", preview: "for second")

    get messages_path(accounts: [ other.id ])

    assert_match(/for second/, response.body)
    refute_match(/for main/, response.body)
    assert_equal [ other.id ], @user.reload.settings["dm_account_filter"]

    # Persisted, so it survives a plain navigation with no params.
    get messages_path
    refute_match(/for main/, response.body)
  end

  def test_opening_a_conversation_shows_both_sides_and_clears_the_unread_count
    convo = conversation(classification: "known", unread_count: 3)
    add_message(convo, content: "the message body")

    get conversation_path(convo)

    assert_response :success
    assert_match(/the message body/, response.body)
    assert_equal 0, convo.reload.unread_count
    assert convo.last_read_at.present?
  end

  # Requirement: which of the user's identities owns the thread must be
  # unmistakable, and both names copy their npub.
  def test_the_thread_header_names_both_sides_with_copyable_npubs
    convo = conversation(classification: "known")
    add_message(convo)

    get conversation_path(convo)

    assert_match(/Main/, response.body)
    assert_match(/data-clipboard-text-value="#{Nostr::KeyConverter.hex_to_npub(@account.pubkey_hex)}"/, response.body)
    assert_match(/data-clipboard-text-value="#{Nostr::KeyConverter.hex_to_npub(@peer)}"/, response.body)
  end

  # clipboard_controller#flash overwrites textContent, so an avatar nested inside
  # the button would be destroyed on the first click.
  def test_the_copyable_name_button_contains_no_nested_elements
    convo = conversation(classification: "known")
    add_message(convo)

    get conversation_path(convo)

    buttons = response.body.scan(/<button[^>]*data-controller="clipboard".*?<\/button>/m)
    assert buttons.any?, "expected copy-npub buttons in the thread header"
    buttons.each do |button|
      refute_match(/<(img|div|span|svg)\b/, button, "a nested element would be wiped by the Copied! flash")
    end
  end

  def test_accepting_a_request_moves_it_to_the_inbox_and_locks_it
    convo = conversation(classification: "request")

    post accept_conversation_path(convo)

    assert_equal "known", convo.reload.classification
    assert convo.classification_locked?
  end

  def test_blocking_a_request_hides_it
    convo = conversation(classification: "request")

    post block_conversation_path(convo)

    assert_equal "muted", convo.reload.classification
    assert convo.classification_locked?
  end

  # A leaked DM is worse than a leaked post.
  def test_another_users_conversation_is_not_reachable
    stranger = create_nostr_user
    stranger_account = stranger.accounts.create!(pubkey_hex: SecureRandom.hex(32), npub: "npub_x")
    theirs = stranger_account.conversations.create!(
      user: stranger, participants_key: SecureRandom.hex(32),
      participant_pubkeys: [ stranger_account.pubkey_hex ], classification: "known"
    )

    # 404, not a raise: the request goes through the full middleware stack, which
    # is what an attacker would actually get.
    get conversation_path(theirs)
    assert_response :not_found

    post accept_conversation_path(theirs)
    assert_response :not_found

    assert_equal "known", theirs.reload.classification, "another user's row must be untouched"
  end

  def test_the_nav_badge_counts_only_the_known_inbox
    conversation(classification: "known", unread_count: 2)
    conversation(classification: "request", unread_count: 7)

    get messages_path

    # 2, not 9: anyone can send a gift wrap, so Requests must not drive the badge.
    assert_equal 2, @user.conversations.active.known.sum(:unread_count)
    assert_match(/>\s*2\s*<\/span>/, response.body)
  end

  # A silently empty inbox needs an explanation that matches what is actually in
  # Amber. The setting is "Client auth whitelist" and it takes hostnames.
  def test_a_blocked_relay_auth_names_the_real_amber_setting_and_the_host
    @account.update!(settings: @account.settings.merge(
      "amber_auth_blocked_at" => Time.current.iso8601,
      "amber_auth_blocked_relay" => "auth.nostr1.com"
    ))

    get messages_path

    assert_match(/Client auth whitelist/, response.body)
    assert_match(/auth\.nostr1\.com/, response.body)
    assert_match(/All relays/, response.body)
    # There is no such settings entry, and no wildcard in the whitelist.
    refute_match(/Settings → Relay authentication/, response.body)
  end

  def test_an_account_needing_a_repair_is_prompted_on_the_inbox
    @account.update!(dm_perms_version: nil)

    get messages_path

    assert_match(/Messaging is not enabled/, response.body)
  end

  # One real user manages 20 accounts; a banner each would bury the inbox.
  def test_many_accounts_needing_repair_collapse_into_one_prompt
    @account.update!(dm_perms_version: nil)
    3.times { |i| paired_account("Extra#{i}").update!(dm_perms_version: nil) }

    get messages_path

    assert_match(/4 accounts need re-pairing/, response.body)
    assert_equal 1, response.body.scan(/need re-pairing before they can/).size
    # Each still reachable from the collapsed list.
    assert_equal 4, response.body.scan(/reason=messaging/).size
  end

  # This is a central inbox, so every account is shown by default — and the pills
  # must look selected to match, not switched off.
  def test_all_account_pills_are_selected_by_default
    other = paired_account("Second")

    get messages_path

    [ @account, other ].each do |account|
      assert_match(/id="dm-account-#{account.id}"[^>]*checked/, response.body,
                   "#{account.display_name} should render as selected when no filter is set")
    end
    refute_match(/Select all/, response.body, "nothing to select when everything is already shown")
  end

  def test_select_all_appears_once_a_subset_is_chosen
    other = paired_account("Second")

    get messages_path(accounts: [ other.id ])

    assert_match(/Select all/, response.body)
    refute_match(/id="dm-account-#{@account.id}"[^>]*checked/, response.body)
  end

  # The filter is persisted, so a "Select all" link that omits the accounts param
  # leaves the stored subset in place and does nothing at all.
  def test_select_all_actually_clears_a_persisted_filter
    other = paired_account("Second")
    get messages_path(accounts: [ other.id ])
    assert_equal [ other.id ], @user.reload.settings["dm_account_filter"]

    # Follow the link the page renders, rather than a URL invented by the test.
    select_all = response.body[%r{href="([^"]*)"[^>]*>\s*Select all}, 1]
    assert select_all, "the Select all link should be on the page"
    get CGI.unescapeHTML(select_all)

    assert_empty @user.reload.settings["dm_account_filter"]
    @user.accounts.each do |account|
      assert_match(/id="dm-account-#{account.id}"[^>]*checked/, response.body,
                   "#{account.display_name} should be selected after Select all")
    end
    refute_match(/Select all/, response.body)
  end

  # Selecting every account by hand is the same state as no filter, so it must
  # collapse — otherwise "Select all" would sit next to an already-complete set.
  def test_selecting_every_account_collapses_to_the_default
    paired_account("Second")
    # Every account the user has, including the one the login flow imports.
    all_ids = @user.accounts.pluck(:id)

    get messages_path(accounts: all_ids)

    assert_empty @user.reload.settings["dm_account_filter"]
    refute_match(/Select all/, response.body)
  end

  def test_selecting_a_strict_subset_is_kept
    other = paired_account("Second")

    get messages_path(accounts: [ other.id ])

    assert_equal [ other.id ], @user.reload.settings["dm_account_filter"]
  end

  # --- unread filter and mark-all-read ---------------------------------------

  def test_filtering_by_unread_shows_only_unread_conversations
    conversation(classification: "known", preview: "already read", unread_count: 0)
    conversation(classification: "known", preview: "still unread", unread_count: 2)

    get messages_path(unread: "1")

    assert_match(/still unread/, response.body)
    refute_match(/already read/, response.body)
  end

  def test_the_unread_filter_is_off_by_default
    conversation(classification: "known", preview: "already read", unread_count: 0)

    get messages_path

    assert_match(/already read/, response.body)
    assert_match(/Filter by unread/, response.body)
  end

  def test_mark_all_read_clears_the_current_tab
    a = conversation(classification: "known", unread_count: 3)
    b = conversation(classification: "known", unread_count: 1)

    post mark_all_read_messages_path(tab: "known")

    assert_equal 0, a.reload.unread_count
    assert_equal 0, b.reload.unread_count
    assert a.last_read_at.present?
  end

  # It must not reach into the other tab — Requests is exactly where a user wants
  # things left alone until they have looked.
  def test_mark_all_read_leaves_the_other_tab_alone
    inbox = conversation(classification: "known", unread_count: 2)
    request = conversation(classification: "request", unread_count: 5)

    post mark_all_read_messages_path(tab: "known")

    assert_equal 0, inbox.reload.unread_count
    assert_equal 5, request.reload.unread_count
  end

  # Nor accounts the user has filtered out of view.
  def test_mark_all_read_honours_the_account_filter
    other = paired_account("Second")
    mine = conversation(account: @account, classification: "known", unread_count: 4)
    theirs = conversation(account: other, classification: "known", unread_count: 6)

    post mark_all_read_messages_path(tab: "known", accounts: [ other.id ])

    assert_equal 0, theirs.reload.unread_count
    assert_equal 4, mine.reload.unread_count, "an account filtered out of view must not be touched"
  end

  # --- composer delivery mode ---------------------------------------------------

  def test_a_peer_with_a_published_inbox_gets_the_private_composer
    convo = conversation(classification: "known")
    DmRelayList.create!(pubkey_hex: @peer, relays: [ "wss://inbox.example" ], fetched_at: Time.current)

    get conversation_path(convo)

    assert_match(/Strong encryption/, response.body)
    refute_match(/Send with public metadata/, response.body)
  end

  # THE guard against pushing people onto NIP-04 for no reason. "We have not
  # looked yet" must never be rendered as "they cannot receive private messages".
  def test_an_unresolved_peer_shows_checking_not_the_downgrade_offer
    convo = conversation(classification: "known")

    get conversation_path(convo)

    assert_match(/Checking where this person receives/, response.body)
    refute_match(/Send with public metadata/, response.body)
    refute_match(/cannot receive private messages/, response.body)
  end

  # A peer with no 10050 can still be sent to, best-effort — but the composer must
  # say where it is going and why it may not arrive, and keep the legacy route
  # visible for clients that have no NIP-17 support at all.
  def test_a_peer_with_no_inbox_gets_a_best_effort_composer_and_a_legacy_option
    convo = conversation(classification: "known")
    DmRelayList.definitive_negative!(@peer)

    get conversation_path(convo)

    assert_match(/has not published a DM inbox/, response.body)
    assert_match(/best-effort delivery/i, response.body)
    assert_match(/may not arrive/, response.body)
    # Naming the clients that will never look is the difference between a warning
    # and an actionable one.
    assert_match(/Primal, Damus/, response.body)
    # And the reliable route is still one click away.
    assert_match(/Send with public metadata/, response.body)
    Message::LEGACY_DOWNGRADE_RISKS.each do |risk|
      assert_includes response.body, ERB::Util.html_escape(risk)
    end
  end

  # The checking state has to resolve itself; telling the user to reload is not a
  # resolution.
  def test_the_checking_composer_carries_what_it_needs_to_resolve_itself
    convo = conversation(classification: "known")

    get conversation_path(convo)

    assert_match(/data-dm-delivery-checking-value="true"/, response.body)
    assert_match(/data-dm-delivery-url-value="#{Regexp.escape(composer_conversation_path(convo))}"/, response.body)
    refute_match(/reload in a moment/, response.body)
  end

  def test_the_composer_endpoint_returns_the_body_without_a_frame_wrapper
    convo = conversation(classification: "known")
    DmRelayList.create!(pubkey_hex: @peer, relays: [ "wss://inbox.example" ], fetched_at: Time.current)

    get composer_conversation_path(convo)

    assert_response :success
    assert_match(/Strong encryption/, response.body)
    # A nested frame would break the in-place swap.
    refute_match(/<turbo-frame/, response.body)
    # Resolved, so the replacement must not start polling again.
    assert_match(/data-dm-delivery-checking-value="false"/, response.body)
  end

  def test_the_composer_endpoint_is_scoped_to_the_current_user
    stranger = create_nostr_user
    stranger_account = stranger.accounts.create!(pubkey_hex: SecureRandom.hex(32), npub: "npub_z")
    theirs = stranger_account.conversations.create!(
      user: stranger, participants_key: SecureRandom.hex(32),
      participant_pubkeys: [ stranger_account.pubkey_hex ], classification: "known"
    )

    get composer_conversation_path(theirs)

    assert_response :not_found
  end

  def test_an_account_without_messaging_permissions_cannot_compose
    @account.update!(dm_perms_version: nil)
    convo = conversation(classification: "known")

    get conversation_path(convo)

    assert_match(/has not granted messaging permissions/, response.body)
  end

  # --- sending ------------------------------------------------------------------

  def test_sending_creates_an_outbound_message_and_enqueues_the_send
    convo = conversation(classification: "known")

    assert_enqueued_with(job: SendDirectMessageJob) do
      post conversation_messages_path(convo), params: { content: "hello there" }
    end

    message = convo.messages.sole
    assert message.outbound?
    assert_equal "pending", message.status
    assert_equal "hello there", message.content
    refute message.legacy_downgrade?
  end

  def test_an_empty_message_is_rejected
    convo = conversation(classification: "known")

    post conversation_messages_path(convo), params: { content: "   " }

    assert_equal 0, convo.messages.count
  end

  # A legacy send must go through the legacy job and carry the stored consent.
  def test_a_legacy_send_records_the_acknowledgement
    convo = conversation(classification: "known", protocol: "nip04")

    assert_enqueued_with(job: SendLegacyDirectMessageJob) do
      post conversation_messages_path(convo), params: { content: "old school", legacy_ack: "1" }
    end

    message = convo.messages.sole
    assert message.legacy_downgrade?
    assert message.legacy_downgrade_acked_at.present?
  end

  # Accepting the downgrade from a NIP-17 room must actually produce a kind-4
  # message. Deciding legacy-vs-NIP-17 from the room alone ignored the
  # acknowledgement and built a NIP-17 message with nowhere to deliver it, which
  # then failed at send time — the user saw only "Failed to send".
  def test_accepting_the_downgrade_from_a_nip17_room_sends_a_legacy_message
    convo = conversation(classification: "known")
    DmRelayList.definitive_negative!(@peer)

    assert_enqueued_with(job: SendLegacyDirectMessageJob) do
      post conversation_messages_path(convo), params: { content: "falling back", legacy_ack: "1" }
    end

    assert_equal 0, convo.messages.count, "the NIP-17 room must not carry a kind-4 message"

    legacy_room = @user.conversations.nip04.sole
    message = legacy_room.messages.sole
    assert_equal Message::LEGACY_KIND, message.kind
    assert message.legacy_downgrade?
    assert_equal @peer, legacy_room.peer_pubkey
    # The two rooms stay distinct but describe the same people.
    assert_equal convo.participants_key, legacy_room.participants_key
    # And the user is taken to the room their message is actually in.
    assert_redirected_to conversation_path(legacy_room)
  end

  def test_a_second_downgrade_reuses_the_same_legacy_room
    convo = conversation(classification: "known")
    DmRelayList.definitive_negative!(@peer)

    2.times { |i| post conversation_messages_path(convo), params: { content: "msg #{i}", legacy_ack: "1" } }

    assert_equal 1, @user.conversations.nip04.count
    assert_equal 2, @user.conversations.nip04.sole.messages.count
  end

  # The model refuses an unacknowledged kind-4 send; the builder refuses earlier.
  def test_a_legacy_send_without_acknowledgement_is_refused
    convo = conversation(classification: "known", protocol: "nip04")

    post conversation_messages_path(convo), params: { content: "sneaky" }

    assert_equal 0, convo.messages.count
  end

  # --- failed messages ----------------------------------------------------------

  def test_a_failed_message_offers_a_retry_when_retrying_could_work
    convo = conversation(classification: "known")
    DmRelayList.create!(pubkey_hex: @peer, relays: [ "wss://inbox.example" ], fetched_at: Time.current)
    failed_message(convo)

    get conversation_path(convo)

    assert_match(/Try again/, response.body)
    refute_match(/Send it as a legacy message instead/, response.body)
  end

  # Retrying a private message to somebody with no kind 10050 is guaranteed to
  # fail identically, so offering it would be a lie.
  def test_a_failed_message_to_a_peer_without_an_inbox_offers_the_downgrade_not_a_retry
    convo = conversation(classification: "known")
    DmRelayList.definitive_negative!(@peer)
    failed_message(convo)

    get conversation_path(convo)

    refute_match(/Try again/, response.body)
    assert_match(/Send it as a legacy message instead/, response.body)
    Message::LEGACY_DOWNGRADE_RISKS.each { |risk| assert_includes response.body, ERB::Util.html_escape(risk) }
  end

  def test_retrying_a_recoverable_message_re_enqueues_it
    convo = conversation(classification: "known")
    DmRelayList.create!(pubkey_hex: @peer, relays: [ "wss://inbox.example" ], fetched_at: Time.current)
    message = failed_message(convo)

    assert_enqueued_with(job: SendDirectMessageJob) { post retry_message_path(message) }

    assert_equal "pending", message.reload.status
    assert_nil message.error
  end

  def test_retrying_an_undeliverable_message_is_refused_with_an_explanation
    convo = conversation(classification: "known")
    DmRelayList.definitive_negative!(@peer)
    message = failed_message(convo)

    assert_no_enqueued_jobs(only: SendDirectMessageJob) { post retry_message_path(message) }

    assert_equal "failed", message.reload.status
    assert_match(/no DM inbox/, flash[:alert])
  end

  # The original was never delivered, so replacing it beats leaving a permanent
  # "Not sent" next to the copy that did go out.
  def test_downgrading_a_failed_message_resends_it_as_legacy_and_replaces_it
    convo = conversation(classification: "known")
    DmRelayList.definitive_negative!(@peer)
    message = failed_message(convo, content: "please read this")

    assert_enqueued_with(job: SendLegacyDirectMessageJob) { post downgrade_message_path(message) }

    assert_nil Message.find_by(id: message.id), "the undelivered original should not linger"
    legacy = @user.conversations.nip04.sole.messages.sole
    assert_equal Message::LEGACY_KIND, legacy.kind
    assert_equal "please read this", legacy.content
    assert legacy.legacy_downgrade_acked_at.present?
    assert_redirected_to conversation_path(legacy.conversation)
  end

  def test_another_users_message_cannot_be_retried_or_downgraded
    stranger = create_nostr_user
    stranger_account = stranger.accounts.create!(pubkey_hex: SecureRandom.hex(32), npub: "npub_w")
    theirs = stranger_account.conversations.create!(
      user: stranger, participants_key: SecureRandom.hex(32),
      participant_pubkeys: [ stranger_account.pubkey_hex ], classification: "known"
    )
    message = theirs.messages.create!(
      account: stranger_account, user: stranger, rumor_id: SecureRandom.hex(32),
      sender_pubkey: stranger_account.pubkey_hex, direction: "outbound", status: "failed",
      sort_at: Time.current, content: "not yours"
    )

    post retry_message_path(message)
    assert_response :not_found
    post downgrade_message_path(message)
    assert_response :not_found
    assert_equal "failed", message.reload.status
  end

  def test_cannot_send_into_another_users_conversation
    stranger = create_nostr_user
    stranger_account = stranger.accounts.create!(pubkey_hex: SecureRandom.hex(32), npub: "npub_y")
    theirs = stranger_account.conversations.create!(
      user: stranger, participants_key: SecureRandom.hex(32),
      participant_pubkeys: [ stranger_account.pubkey_hex ], classification: "known"
    )

    post conversation_messages_path(theirs), params: { content: "not yours" }

    assert_response :not_found
    assert_equal 0, theirs.messages.count
  end

  private

  def assigns_conversations
    @user.conversations.active.known.to_a
  end

  def paired_account(name)
    @user.accounts.create!(
      pubkey_hex: SecureRandom.hex(32), display_name: name, npub: "npub_#{name.downcase}",
      signer_pubkey: SecureRandom.hex(32), app_privkey: SecureRandom.hex(32),
      app_pubkey: SecureRandom.hex(32),
      dm_perms_version: Nostr::AuthService::PERMISSIONS_VERSION
    )
  end

  def conversation(account: @account, classification: "known", preview: "hello", unread_count: 0, **attrs)
    account.conversations.create!({
      user: @user,
      participants_key: SecureRandom.hex(32),
      participant_pubkeys: [ account.pubkey_hex, @peer ],
      peer_pubkey: @peer,
      classification: classification,
      last_message_preview: preview,
      last_message_at: Time.current,
      unread_count: unread_count
    }.merge(attrs))
  end

  def failed_message(conversation, content: "did not go out")
    conversation.messages.create!(
      account: conversation.account, user: @user,
      rumor_id: SecureRandom.hex(32), sender_pubkey: conversation.account.pubkey_hex,
      direction: "outbound", status: "failed", sort_at: Time.current,
      rumor_created_at: Time.current, content: content,
      error: "No relay accepted the message."
    )
  end

  def add_message(conversation, content: "hi there")
    conversation.messages.create!(
      account: conversation.account, user: @user,
      rumor_id: SecureRandom.hex(32), sender_pubkey: @peer,
      direction: "inbound", status: "received", sort_at: Time.current,
      rumor_created_at: Time.current, content: content
    )
  end
end
