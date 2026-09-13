# frozen_string_literal: true

# The console's shared vocabulary: lamps, poll strips, identity and the station
# status bank. Presentation only — RelayDelivery decides what the numbers are.
module ConsoleHelper
  # The lamp bank at the foot of the rail. Four readings the operator needs
  # before anything else, in the order they matter:
  #
  #   identities  — how many accounts this login speaks for
  #   waiting     — how many events are sitting on a human right now
  #   short       — published but reached fewer relays than they were sent to
  #   failed      — never went out at all
  #
  # `short` is the reading this app never had. It has to be computed in Ruby
  # because publish_results is a JSON blob, so it is scoped to a recent window
  # rather than the whole history: a short pull from three months ago is not a
  # thing anyone is going to act on, and counting it would cost a full scan.
  SHORT_DELIVERY_WINDOW = 7.days

  def station_status
    @station_status ||= begin
      accounts = current_user.accounts
      account_ids = accounts.pluck(:id)

      recent_published = Post.where(account_id: account_ids, status: :published)
                             .where(published_at: SHORT_DELIVERY_WINDOW.ago..)
                             .select(:id, :publish_results, :status)

      {
        identities: account_ids.size,
        waiting: Post.where(account_id: account_ids, status: :awaiting_signature).count +
                 Repost.where(account_id: account_ids, status: %i[awaiting_signature pending_signature]).count,
        short: recent_published.count(&:delivery_alarming?),
        failed: Post.where(account_id: account_ids, status: :failed).count +
                Repost.where(account_id: account_ids, status: :failed).count
      }
    end
  end

  # `publish_results` usually maps relay => reason, but a record that failed
  # before it ever reached a relay carries a single {"error" => why} instead.
  # Run through the relay formatter that becomes "error Signing was never
  # completed…", so the non-relay key is dropped rather than printed as a host.
  def delivery_failure_line(record)
    line = record.delivery_failures.first(2).map do |relay, why|
      relay.to_s == "error" ? why.to_s : "#{relay.to_s.sub(%r{\Awss?://}, '')} #{why}"
    end.join(" · ")
    line.presence
  end

  # A repost's row links to the note it reposts — a repost has no page of its
  # own, and the note's page is where its retry and rebroadcast controls live.
  def forme_target(record)
    record.is_a?(Repost) ? record.post : record
  end

  # An indicator lamp. Unlit is the default, because nominal does not illuminate.
  def lamp(state = :off, title: nil)
    modifier = { on: " lamp--lit", alarm: " lamp--alarm", wait: " lamp--wait" }[state].to_s
    tag.span(nil, class: "lamp#{modifier}", title: title, aria: { hidden: true })
  end

  # One cell per relay the event was sent to: filled for a relay that took it,
  # red for one that did not, and the tally spelled out beside it. A screen
  # reader gets the sentence, not the lamps.
  def poll_strip(record)
    return nil if record.delivery_total.zero?

    alarming = record.delivery_alarming?
    cells = record.delivery_results.map do |relay, result|
      ok = result.to_s == "ok"
      # An unlit cell already says "this one did not take it". Red is reserved
      # for a delivery that actually failed to reach the network.
      state = if ok then "is-ok" elsif alarming then "is-short" else "" end
      tag.i(nil, class: state, title: "#{relay} — #{ok ? 'accepted' : result}")
    end

    tag.span(class: "inline-flex items-center gap-2.5") do
      tag.span(safe_join(cells), class: "strip", aria: { hidden: true }) +
        tag.span(record.delivery_tally,
                 class: "font-mono text-[15px] font-bold tabular #{record.delivery_alarming? ? 'text-red-600 dark:text-red-400' : 'text-gray-500 dark:text-gray-400'}") +
        tag.span(delivery_sentence(record), class: "sr-only")
    end
  end

  def delivery_sentence(record)
    case record.delivery_grade
    when :all then "Reached all #{record.delivery_total} relays."
    when :partial then "Reached #{record.delivery_ok_count} of #{record.delivery_total} relays, which is a normal publish."
    when :thin then "Reached only 1 of #{record.delivery_total} relays — effectively invisible."
    when :none then "Reached none of the #{record.delivery_total} relays it was sent to."
    else "Not published yet."
    end
  end

  # The identity rule. Its hue comes from the pubkey, so it is the same mark on
  # every surface and never shifts when a new account is paired.
  def wire(account, height: nil)
    tag.span(nil, class: "wire", style: "--wire-ink: #{account.ink};#{" min-height: #{height}" if height}",
                  aria: { hidden: true })
  end

  # The account's face. A real picture identifies an identity far faster than a
  # letter does, which is the whole job of this mark in a list of nineteen.
  def chop(account, size: 26)
    if account.picture_url.present?
      tag.img(src: account.picture_url, alt: "", loading: "lazy", referrerpolicy: "no-referrer",
              class: "flex-none object-cover", width: size, height: size,
              style: "width:#{size}px;height:#{size}px;--wire-ink: #{account.ink}")
    else
      tag.span(account.chop, class: "chop", style: "--wire-ink: #{account.ink}; width:#{size}px; height:#{size}px",
                             aria: { hidden: true })
    end
  end

  # Identity, stated the same way everywhere: rule, face, name.
  #
  # No npub. A truncated `npub14lu…` identifies nothing — the first characters
  # are the shared human-readable prefix, so every account looks alike — and it
  # cost the name its room, forcing a truncation that hid the thing that does
  # identify. The name now wraps to two lines, and the whole block links to the
  # account for the rare case where the key itself is wanted.
  def identity(account, link: true, size: 26)
    inner = tag.span(class: "flex items-center gap-2.5 min-w-0") do
      wire(account) + chop(account, size: size) +
        tag.span(account.display_name_or_npub,
                 class: "condensed text-[15px] font-semibold uppercase leading-[1.2] tracking-[0.1em] line-clamp-2")
    end

    return inner unless link

    link_to(inner, account_path(account),
            class: "block min-w-0 no-underline transition-colors hover:text-amber-600 dark:hover:text-amber-400",
            title: account.display_name_or_npub)
  end

  # The status slug. Nominal is quiet; only waiting-on-a-human and short
  # delivery carry colour.
  def status_slug(record)
    case record.status
    when "awaiting_signature", "pending_signature"
      tag.span("Approve on phone", class: "slug slug--wait")
    when "published"
      record.delivery_alarming? ? tag.span("Barely out #{record.delivery_tally}", class: "slug slug--short") : nil
    when "failed"
      tag.span("Failed", class: "slug slug--short")
    when "publishing"
      tag.span("Sending", class: "slug")
    when "scheduled"
      tag.span("Held", class: "slug")
    else
      tag.span(status_label(record.status), class: "slug")
    end
  end
end
