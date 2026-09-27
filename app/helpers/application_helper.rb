module ApplicationHelper
  # Language names are always shown in their own language, so a visitor who
  # landed in the wrong one can still find theirs.
  LOCALE_NAMES = { "en" => "English", "sk" => "Slovenčina", "cs" => "Čeština", "es" => "Español" }.freeze

  # The `js` subtree for the current locale, over English so a key missing
  # from a translation still reads as something instead of its key.
  def js_translations
    english = I18n.t("js", locale: :en, default: {})
    return english if I18n.locale == :en

    english.deep_merge(I18n.t("js", default: {}))
  end

  # `awaiting_signature` reads as internal jargon to end users — show a
  # friendlier label everywhere a post/repost status is displayed (L28).
  # Looked up at call time (config/locales/core: status_labels.*) so it follows
  # the request's language; an unknown status still reads as itself.
  def status_label(status)
    return status.to_s.humanize if status.blank?

    I18n.t("status_labels.#{status}", default: status.to_s.humanize)
  end

  def local_time(time, format: "datetime")
    return "" if time.nil?

    # Rendered server-side in the user's own zone (ApplicationController sets
    # Time.zone per request), so this text is already correct and the client-side
    # pass in local_time_controller.js agrees with it instead of replacing a UTC
    # value a moment later. It still runs, because a user reading from a second
    # machine in another zone should see that machine's clock.
    #
    # The fallback used to be suffixed "UTC" unconditionally. That was true when
    # the server rendered UTC and is a lie now, so the zone is named from the
    # instant itself — and the title keeps the unambiguous absolute one (L24).
    local = time.in_time_zone(Time.zone)
    fallback = case format
               when "time" then I18n.l(local, format: :app_time)
               when "date" then I18n.l(local, format: :app_date)
               when "short" then I18n.l(local, format: :app_short)
               else I18n.l(local, format: :app_datetime)
               end
    tag.time(
      fallback,
      datetime: local.iso8601,
      title: "#{local.strftime('%Y-%m-%d %H:%M:%S %Z')} · #{time.utc.strftime('%H:%M UTC')}",
      data: { local_time_format: format }
    )
  end

  def nevent_url(nevent, viewer = nil)
    viewer ||= current_user&.event_viewer || "njump"
    case viewer
    when "yakihonne"
      "https://yakihonne.com/note/#{nevent}"
    else
      "https://njump.me/#{nevent}"
    end
  end

  def interaction_type_badge_class(type)
    case type.to_sym
    when :reply
      "bg-blue-100 text-blue-800 dark:bg-blue-900 dark:text-blue-200"
    when :quote
      "bg-purple-100 text-purple-800 dark:bg-purple-900 dark:text-purple-200"
    when :mention
      "bg-gray-100 text-gray-800 dark:bg-gray-700 dark:text-gray-200"
    else
      "bg-gray-100 text-gray-800 dark:bg-gray-700 dark:text-gray-200"
    end
  end

  def nprofile_url(npub, viewer = nil)
    viewer ||= current_user&.event_viewer || "njump"
    case viewer
    when "yakihonne"
      "https://yakihonne.com/profile/#{npub}"
    else
      "https://njump.me/#{npub}"
    end
  end
end
