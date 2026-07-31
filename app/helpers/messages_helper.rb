# frozen_string_literal: true

module MessagesHelper
  # Runs on every authenticated page render (the nav badge), so the cache is not
  # optional. Busted on ingest and on mark-read.
  UNREAD_TTL = 30.seconds

  def self.unread_cache_key(user) = "dm_unread_user_#{user.id}"

  # Deliberately counts `known` only. Spam must never be able to drive the nav
  # badge — Requests gets an unnumbered dot instead.
  def dm_unread_count(user)
    Rails.cache.fetch(MessagesHelper.unread_cache_key(user), expires_in: UNREAD_TTL) do
      user.conversations.active.known.sum(:unread_count)
    end
  end

  def dm_has_requests?(user)
    Rails.cache.fetch("dm_requests_user_#{user.id}", expires_in: UNREAD_TTL) do
      user.conversations.active.request.with_unread.exists?
    end
  end

  # Display name for a pubkey, falling back to a shortened npub.
  def dm_display_name(pubkey_hex)
    return "Unknown" if pubkey_hex.blank?

    resolve_author_name(pubkey_hex).presence || dm_short_npub(pubkey_hex)
  end

  def dm_npub(pubkey_hex)
    return nil if pubkey_hex.blank?

    Nostr::KeyConverter.hex_to_npub(pubkey_hex)
  end

  def dm_short_npub(pubkey_hex)
    npub = dm_npub(pubkey_hex)
    npub ? "#{npub[0, 12]}…#{npub[-4, 4]}" : pubkey_hex.to_s.first(12)
  end

  def dm_avatar_url(pubkey_hex)
    return nil if pubkey_hex.blank?

    account = Account.find_by(pubkey_hex: pubkey_hex)
    return account.picture_url if account&.picture_url.present?

    profile = cached_profile(pubkey_hex)
    profile&.dig(:picture) || profile&.dig("picture")
  end

  # The other side of a conversation, as one label. Groups have no single peer.
  def dm_peer_label(conversation)
    peers = conversation.peer_pubkeys
    return "Note to self" if peers.empty?
    return dm_display_name(peers.first) if peers.size == 1

    "#{dm_display_name(peers.first)} +#{peers.size - 1}"
  end

  def dm_classification_badge(conversation)
    case conversation.classification_reason
    when "own_follow"     then "You follow them"
    when "sibling_follow" then "Followed by another of your accounts"
    when "wot"            then "Followed by someone you follow"
    when "replied"        then "You replied"
    when "self"           then "Your own account"
    when "manual"         then "You accepted"
    end
  end
end
