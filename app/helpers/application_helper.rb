module ApplicationHelper
  # `awaiting_signature` reads as internal jargon to end users — show a
  # friendlier label everywhere a post/repost status is displayed (L28).
  STATUS_LABELS = {
    "awaiting_signature" => "Waiting for approval in signer"
  }.freeze

  def status_label(status)
    STATUS_LABELS[status.to_s] || status.to_s.humanize
  end

  def local_time(time, format: "datetime")
    return "" if time.nil?
    fallback = case format
               when "time" then time.strftime("%H:%M UTC")
               when "date" then time.strftime("%b %d, %Y")
               when "short" then time.strftime("%b %d, %H:%M UTC")
               else time.strftime("%b %d, %Y %H:%M UTC")
               end
    tag.time(
      fallback,
      datetime: time.iso8601,
      # The rendered text reformats client-side to local time (local_time_controller.js)
      # and can flash the server-rendered UTC fallback first — a title with the
      # unambiguous absolute instant is always correct either way (L24).
      title: time.strftime("%Y-%m-%d %H:%M:%S UTC"),
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
