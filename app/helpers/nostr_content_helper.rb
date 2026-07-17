# frozen_string_literal: true

module NostrContentHelper
  NOSTR_URI_PATTERN = /nostr:(nprofile1[a-z0-9]+|npub1[a-z0-9]+|nevent1[a-z0-9]+|note1[a-z0-9]+|naddr1[a-z0-9]+)/i

  def render_nostr_content(content)
    return "" if content.blank?

    escaped = h(content)

    resolved = escaped.gsub(NOSTR_URI_PATTERN) do |match|
      identifier = match.sub(/\Anostr:/i, "")
      resolve_nostr_reference(identifier)
    end

    resolved.html_safe
  end

  private

  def resolve_nostr_reference(identifier)
    parsed = Nostr::KeyConverter.parse_nostr_identifier(identifier)
    return "nostr:#{identifier}" unless parsed

    case parsed[:type]
    when :nprofile, :npub
      resolve_profile_reference(identifier, parsed)
    when :nevent, :note
      resolve_event_reference(identifier, parsed)
    when :naddr
      resolve_naddr_reference(identifier, parsed)
    else
      "nostr:#{identifier}"
    end
  end

  def resolve_profile_reference(identifier, parsed)
    pubkey_hex = parsed[:pubkey]
    return "nostr:#{identifier}" unless pubkey_hex

    npub = Nostr::KeyConverter.hex_to_npub(pubkey_hex)

    # DB lookup first: Account then User
    account = Account.find_by(pubkey_hex: pubkey_hex)
    known_user = User.find_by(pubkey_hex: pubkey_hex) unless account
    display_name = account&.display_name.presence || account&.username.presence ||
                   known_user&.display_name.presence || known_user&.username.presence

    # Fetch from relays if not found locally
    unless display_name.present?
      relay_hints = parsed[:relays] || []
      profile = cached_profile(pubkey_hex, relay_hints: relay_hints)
      display_name = profile&.dig(:display_name) || profile&.dig(:username)
    end

    label = display_name.present? ? "@#{display_name}" : "@#{npub&.truncate(20)}"

    url = nprofile_url(npub || identifier)
    link_to(label, url, target: "_blank", rel: "noopener noreferrer",
            class: "text-amber-600 dark:text-amber-400 hover:underline font-medium",
            title: npub)
  end

  def resolve_event_reference(identifier, parsed)
    url = nevent_url(identifier)

    # Try fetching from relays
    fetched = cached_event(parsed[:event_id]) if parsed[:event_id]
    if fetched&.dig(:content).present?
      author_name = resolve_author_name(fetched[:pubkey])
      render_inline_note_card(fetched[:content], author_name, url, identifier)
    else
      link_to("[referenced note]", url, target: "_blank", rel: "noopener noreferrer",
              class: "text-amber-600 dark:text-amber-400 hover:underline",
              title: identifier)
    end
  end

  def resolve_naddr_reference(identifier, parsed)
    url = nevent_url(identifier) # njump handles naddr too
    label = parsed[:identifier].present? ? parsed[:identifier].truncate(40) : identifier.truncate(20)
    link_to(label, url, target: "_blank", rel: "noopener noreferrer",
            class: "text-amber-600 dark:text-amber-400 hover:underline",
            title: identifier)
  end

  def render_inline_note_card(content, author_name, url, identifier)
    author_label = author_name.present? ? h(author_name) : "Unknown"
    truncated_content = h(content.truncate(300))

    <<~HTML
      <a href="#{h(url)}" target="_blank" rel="noopener noreferrer" title="#{h(identifier)}"
         class="block border border-gray-200 dark:border-gray-600 rounded-lg p-3 my-2 bg-gray-50 dark:bg-gray-700 hover:bg-gray-100 dark:hover:bg-gray-600 transition-colors no-underline cursor-pointer">
        <span class="text-xs font-medium text-amber-600 dark:text-amber-400">#{author_label}</span>
        <span class="block text-sm text-gray-700 dark:text-gray-200 mt-1 whitespace-pre-wrap">#{truncated_content}</span>
      </a>
    HTML
  end

  def cached_profile(pubkey_hex, relay_hints: [])
    Rails.cache.fetch("nostr_profile:#{pubkey_hex}", expires_in: 1.day) do
      fetcher = Nostr::ProfileFetcher.new
      # Try relay hints first, then fall back to default relays
      if relay_hints.any?
        # ProfileFetcher doesn't accept relay_hints, but we can try fetching
        fetcher.fetch(pubkey_hex)
      else
        fetcher.fetch(pubkey_hex)
      end
    end
  rescue => e
    Rails.logger.warn "Failed to fetch profile #{pubkey_hex}: #{e.message}"
    nil
  end

  def cached_event(event_id_hex)
    Rails.cache.fetch("nostr_event:#{event_id_hex}", expires_in: 1.day) do
      result = Nostr::EventFetcher.new.fetch_by_ids([event_id_hex])
      event = result&.values&.first
      if event
        { content: event["content"], pubkey: event["pubkey"], kind: event["kind"] }
      end
    end
  rescue => e
    Rails.logger.warn "Failed to fetch event #{event_id_hex}: #{e.message}"
    nil
  end

  def resolve_author_name(pubkey_hex)
    return nil unless pubkey_hex

    account = Account.find_by(pubkey_hex: pubkey_hex)
    return account.display_name.presence || account.username.presence if account

    known_user = User.find_by(pubkey_hex: pubkey_hex)
    return known_user.display_name || known_user.username if known_user

    profile = cached_profile(pubkey_hex)
    profile&.dig(:display_name) || profile&.dig(:username)
  end
end
