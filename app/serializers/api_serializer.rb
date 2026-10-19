# frozen_string_literal: true

# JSON shapes for /api/v1 (the native app). One place, so every endpoint that
# returns a post returns the same post.
#
# Conventions: times are ISO8601 UTC (the client renders them in the user's
# zone), ids are integers, Nostr keys come as both hex and bech32, and anything
# the web would have linked to an event viewer carries the viewer URL too — the
# app prefers handing a `nostr:` URI to an installed Nostr client and falls
# back to that URL.
#
# Names and quoted notes are resolved exactly the way the web renders them
# (NostrContentHelper / MessagesHelper): from the database first, then the
# profile cache, never a blocking relay call.
class ApiSerializer
  include NostrContentHelper
  include MessagesHelper

  def initialize(user)
    @user = user
  end

  # --- people ------------------------------------------------------------------

  def user(user = @user)
    {
      id: user.id,
      npub: user.npub,
      pubkey_hex: user.pubkey_hex,
      display_name: user.display_name,
      username: user.username,
      about: user.about,
      picture_url: user.picture_url,
      name: user.display_name_or_npub,
      settings: {
        locale: user.locale,
        timezone: user.timezone,
        theme: user.theme,
        event_viewer: user.event_viewer,
        custom_relays: user.custom_relays,
        media: MediaPreferences.for(user)
      }
    }
  end

  # One @mention suggestion (Mentions::Search::Result). `mention` is the text
  # the composer inserts.
  def mention(result)
    {
      pubkey: result.pubkey_hex,
      npub: result.npub,
      name: result.name,
      display_name: result.display_name,
      nip05: result.nip05,
      picture_url: result.picture_url,
      own: result.own,
      account_id: result.account_id,
      mention: "nostr:#{result.npub}"
    }
  end

  def account_mini(account)
    return nil unless account

    {
      id: account.id,
      name: account.display_name_or_npub,
      username: account.username,
      picture_url: account.picture_url,
      npub: account.npub,
      ink: account.ink,
      chop: account.chop,
      has_signer: account.has_signer?
    }
  end

  def account(account, counts: nil)
    account_mini(account).merge(
      pubkey_hex: account.pubkey_hex,
      display_name: account.display_name,
      about: account.about,
      personality: account.personality,
      write_relays: account.write_relays,
      read_relays: account.read_relays,
      signer_relay: account.signer_relay,
      blossom_server: account.blossom_server,
      blossom_server_override: account.settings&.dig("blossom_server"),
      default_blossom_server: Account.default_blossom_server,
      messaging_capable: account.messaging_capable?,
      needs_messaging_repair: account.needs_messaging_repair?,
      messaging_denied: account.messaging_denied?,
      relay_auth_blocked: account.relay_auth_blocked?,
      relay_auth_blocked_relay: account.settings&.dig("amber_auth_blocked_relay"),
      profile_editing_capable: account.profile_editing_capable?,
      profile_url: viewer_profile_url(account.npub),
      counts: counts,
      created_at: time(account.created_at)
    )
  end

  # --- posts --------------------------------------------------------------------

  def post(post, detail: false)
    data = {
      type: "post",
      id: post.id,
      account_id: post.account_id,
      account: account_mini(post.account),
      content: post.content,
      status: post.status,
      event_kind: post.event_kind,
      is_reply: post.is_reply?,
      reply_to_event_id: post.reply_to_event_id,
      reply_to_pubkey: post.reply_to_pubkey,
      reply_to_nevent: (nevent_for(post.reply_to_event_id, post.reply_to_pubkey) if post.is_reply?),
      reply_to_viewer_url: (viewer_event_url(post.reply_to_event_id, post.reply_to_pubkey) if post.is_reply?),
      root_event_id: post.root_event_id,
      scheduled_at: time(post.scheduled_at),
      published_at: time(post.published_at),
      created_at: time(post.created_at),
      updated_at: time(post.updated_at),
      event_id: post.event_id,
      nevent: nevent_for(post.event_id, post.account.pubkey_hex),
      viewer_url: viewer_event_url(post.event_id, post.account.pubkey_hex),
      delivery: delivery(post, detail: detail),
      error: record_error(post),
      reposts_count: post.reposts.size,
      can: {
        edit: post.can_edit?,
        schedule: post.can_schedule?,
        cancel: post.can_cancel?,
        reschedule: post.can_reschedule?,
        retry_sign: post.can_retry_sign?,
        retry_publish: post.can_retry_publish?,
        rebroadcast: post.can_rebroadcast?
      }
    }

    if detail
      data[:reposts] = post.reposts.includes(:account).sort_by { |r| r.scheduled_at || r.created_at }.map { |r| repost(r) }
      data[:version_history] = post.version_history || []
      data[:references] = references(post.content)
    end
    data
  end

  def repost(repost, with_post: false)
    data = {
      type: "repost",
      id: repost.id,
      post_id: repost.post_id,
      account_id: repost.account_id,
      account: account_mini(repost.account),
      content: repost.post&.content,
      status: repost.status,
      scheduled_at: time(repost.scheduled_at),
      published_at: time(repost.published_at),
      created_at: time(repost.created_at),
      updated_at: time(repost.updated_at),
      delay_minutes: repost.delay_minutes,
      event_id: repost.event_id,
      delivery: delivery(repost, detail: true),
      error: record_error(repost),
      can: {
        cancel: repost.can_cancel?,
        rebroadcast: repost.can_rebroadcast?,
        retry_sign: repost.can_retry_sign?,
        publish_now: repost.can_publish_now?
      }
    }
    data[:post] = { id: repost.post_id, account: account_mini(repost.post&.account), status: repost.post&.status } if with_post
    data
  end

  # A mixed list (dashboard sections, the failed filter, the calendar).
  def row(record)
    record.is_a?(Repost) ? repost(record, with_post: true) : post(record)
  end

  # --- messaging ----------------------------------------------------------------

  def conversation(conversation)
    peers = conversation.peer_pubkeys
    {
      id: conversation.id,
      account: account_mini(conversation.account),
      title: conversation.subject.presence || dm_peer_label(conversation),
      subject: conversation.subject,
      peers: peers.map { |pk| person(pk) },
      protocol: conversation.protocol,
      legacy: conversation.legacy?,
      group: conversation.group?,
      classification: conversation.classification,
      classification_reason: conversation.classification_reason,
      classification_badge: dm_classification_badge(conversation),
      unread_count: conversation.unread_count,
      last_message_at: time(conversation.last_message_at),
      last_message_preview: conversation.last_message_preview,
      last_message_from_self: conversation.last_message_from_self
    }
  end

  def message(message)
    {
      id: message.id,
      conversation_id: message.conversation_id,
      direction: message.direction,
      kind: message.kind,
      legacy: message.legacy?,
      file: message.file?,
      content: message.file? ? nil : message.content,
      subject: message.subject,
      sender: person(message.sender_pubkey),
      sent_at: time(message.rumor_created_at || message.sort_at),
      status: message.status,
      sending: message.sending?,
      step: message.step,
      error: message.error,
      can_retry: message.can_retry?,
      delivery_tier: message.delivery_tier,
      delivery_note: message.delivery_note,
      legacy_downgrade: message.legacy_downgrade?,
      reply_to_rumor_id: message.reply_to_rumor_id,
      rumor_id: message.rumor_id,
      references: message.file? ? [] : references(message.content)
    }
  end

  def person(pubkey_hex)
    {
      pubkey_hex: pubkey_hex,
      npub: dm_npub(pubkey_hex),
      name: dm_display_name(pubkey_hex),
      picture_url: dm_avatar_url(pubkey_hex),
      profile_url: viewer_profile_url(dm_npub(pubkey_hex))
    }
  end

  # --- interactions ---------------------------------------------------------------

  def interaction(item)
    account = item[:target_account]
    {
      event_id: item[:event_id],
      type: item[:interaction_type].to_s,
      content: item[:content],
      created_at: item[:created_at] ? Time.at(item[:created_at]).utc.iso8601 : nil,
      author: {
        pubkey_hex: item[:author_pubkey],
        npub: dm_npub(item[:author_pubkey]),
        name: item[:author_name],
        picture_url: item[:author_picture],
        profile_url: viewer_profile_url(dm_npub(item[:author_pubkey]))
      },
      account: account_mini(account),
      relay_hint: item[:relay_hint],
      root_event_id: item[:referenced_event_ids]&.first,
      already_following: item[:already_following] || false,
      already_liked: item[:already_liked] || false,
      nevent: nevent_for(item[:event_id], item[:author_pubkey]),
      viewer_url: viewer_event_url(item[:event_id], item[:author_pubkey]),
      original: original_post(item),
      references: references(item[:content])
    }
  end

  # A raw kind-1 event from a relay (an account's recent notes).
  def event(event)
    {
      id: event["id"],
      pubkey: event["pubkey"],
      kind: event["kind"],
      content: event["content"],
      created_at: event["created_at"] ? Time.at(event["created_at"].to_i).utc.iso8601 : nil,
      nevent: nevent_for(event["id"], event["pubkey"]),
      viewer_url: viewer_event_url(event["id"], event["pubkey"]),
      references: references(event["content"])
    }
  end

  # --- uploads, billing ---------------------------------------------------------------

  def upload(upload)
    upload.as_status_json.merge(byte_size: upload.byte_size, content_type: upload.content_type)
  end

  def billing(snapshot, plans: nil, settled: nil)
    {
      enabled: Billing.enabled?,
      product: Billing::PRODUCT,
      state: snapshot.state,
      until: time(snapshot.until_time),
      allows_ai: snapshot.allows?,
      others: (NostrBilling::PRODUCTS - [ Billing::PRODUCT ]).filter_map do |product|
        next unless snapshot.active?(product) || snapshot.trial?(product)

        { product: product, state: snapshot.state(product), until: time(snapshot.until_time(product)) }
      end,
      plans: plans && Billing::PLANS.filter_map do |plan|
        details = plans[plan] or next
        { id: plan, sats: details["sats"], days: details["days"] }
      end,
      min_sats: Billing::Checkout::MIN_SATS,
      max_sats: Billing::Checkout::MAX_SATS,
      free_account_limit: Billing::FREE_ACCOUNT_LIMIT,
      settled: settled
    }
  end

  # --- content ------------------------------------------------------------------------

  # Every `nostr:` reference in a text, resolved the way the web renders it:
  # profiles become @names, notes carry their cached text for an inline quote.
  # `match` is the exact substring, so the client can replace it in place.
  def references(content)
    return [] if content.blank?

    # The pattern has capture groups, so scan would yield the groups; take the
    # whole match instead.
    matches = content.to_s.to_enum(:scan, NOSTR_URI_PATTERN).map { Regexp.last_match(0) }
    matches.uniq.first(50).filter_map do |match|
      identifier = match.sub(/\Anostr:/i, "")
      parsed = Nostr::KeyConverter.parse_nostr_identifier(identifier)
      next unless parsed

      case parsed[:type]
      when :npub, :nprofile
        next unless parsed[:pubkey]

        npub = Nostr::KeyConverter.hex_to_npub(parsed[:pubkey])
        name = resolve_author_name(parsed[:pubkey])
        { match: match, type: "profile", identifier: identifier, pubkey_hex: parsed[:pubkey],
          label: name.present? ? "@#{name}" : "@#{npub&.truncate(20)}", url: viewer_profile_url(npub) }
      when :nevent, :note
        fetched = cached_event(parsed[:event_id]) if parsed[:event_id]
        quote = if fetched&.dig(:content).present?
          { author: resolve_author_name(fetched[:pubkey]), content: fetched[:content].to_s.truncate(300) }
        end
        { match: match, type: "event", identifier: identifier, event_id: parsed[:event_id],
          label: I18n.t("nostr_content.referenced_note"), url: viewer_url_for(identifier, :event), quote: quote }
      when :naddr
        { match: match, type: "address", identifier: identifier,
          label: parsed[:identifier].present? ? parsed[:identifier].truncate(40) : identifier.truncate(20),
          url: viewer_url_for(identifier, :event) }
      end
    end
  end

  def time(value) = value&.utc&.iso8601

  private

  # NostrContentHelper/MessagesHelper read the viewer preference from here.
  def current_user = @user

  def nevent_url(nevent, viewer = nil) = viewer_url_for(nevent, :event, viewer)
  def nprofile_url(npub, viewer = nil) = viewer_url_for(npub, :profile, viewer)

  def viewer_url_for(identifier, type, viewer = nil)
    return nil if identifier.blank?

    viewer ||= @user&.event_viewer || "njump"
    if viewer == "yakihonne"
      "https://yakihonne.com/#{type == :profile ? 'profile' : 'note'}/#{identifier}"
    else
      "https://njump.me/#{identifier}"
    end
  end

  def viewer_profile_url(npub) = viewer_url_for(npub, :profile)

  def nevent_for(event_id, author_pubkey)
    return nil if event_id.blank?

    Nostr::KeyConverter.hex_to_nevent(event_id, author_pubkey: author_pubkey)
  rescue StandardError
    nil
  end

  def viewer_event_url(event_id, author_pubkey) = viewer_url_for(nevent_for(event_id, author_pubkey), :event)

  def delivery(record, detail:)
    data = {
      grade: record.delivery_grade.to_s,
      ok: record.delivery_ok_count,
      total: record.delivery_total,
      tally: record.delivery_tally,
      short: record.delivery_short?,
      alarming: record.delivery_alarming?
    }
    if detail
      data[:results] = record.delivery_results.except("error").map { |relay, result| { relay: relay, result: result.to_s } }
    end
    data
  end

  # Signing failures are written as publish_results["error"] rather than a
  # per-relay result.
  def record_error(record)
    results = record.publish_results
    results.is_a?(Hash) ? results["error"] : nil
  end

  def original_post(item)
    return nil if item[:original_post_content].blank?

    {
      content: item[:original_post_content].to_s.truncate(4000),
      owned: item[:original_post_is_owned] || false,
      post_id: item[:original_post_db_id],
      event_id: item[:original_post_event_id],
      author_name: item[:original_post_author],
      author_pubkey: item[:original_post_author_pubkey],
      viewer_url: viewer_event_url(item[:original_post_event_id], item[:original_post_author_pubkey])
    }
  end
end
