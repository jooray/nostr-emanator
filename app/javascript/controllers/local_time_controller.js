import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static values = { zone: String }

  connect() {
    this.reportZone()
    this.formatAll()
    // Watch for Turbo Stream DOM insertions
    this.observer = new MutationObserver((mutations) => {
      for (const mutation of mutations) {
        for (const node of mutation.addedNodes) {
          if (node.nodeType === Node.ELEMENT_NODE) {
            if (node.tagName === "TIME" && node.hasAttribute("datetime")) {
              this.formatElement(node)
            }
            node.querySelectorAll?.("time[datetime]").forEach(el => this.formatElement(el))
          }
        }
      }
    })
    this.observer.observe(this.element, { childList: true, subtree: true })
  }

  disconnect() {
    this.observer?.disconnect()
  }

  // The server renders every time in the zone it has on file for this user, so
  // it needs to have one. This used to be detected only by the scheduler
  // controller, on one page — so until you opened "Schedule", the whole app
  // rendered UTC. This controller is on <body> everywhere, so the zone is
  // learned on whatever page you happen to land on first.
  //
  // Only reported when it actually differs from what the server already knows,
  // so the common case costs no request. A changed answer is worth sending: it
  // means a flight, or a DST boundary the stored name already covers.
  reportZone() {
    let browserZone
    try {
      browserZone = Intl.DateTimeFormat().resolvedOptions().timeZone
    } catch {
      return
    }
    if (!browserZone || browserZone === this.zoneValue) return

    const csrfToken = document.querySelector("meta[name='csrf-token']")?.content
    fetch("/user", {
      method: "PATCH",
      headers: { "Content-Type": "application/json", "X-CSRF-Token": csrfToken },
      body: JSON.stringify({ timezone: browserZone })
    }).catch(() => {
      // Best-effort: a failed report just leaves the stored zone in place.
    })
  }

  formatAll() {
    this.element.querySelectorAll("time[datetime]").forEach(el => this.formatElement(el))
  }

  formatElement(el) {
    const datetime = el.getAttribute("datetime")
    if (!datetime) return

    const date = new Date(datetime)
    if (isNaN(date)) return

    const format = el.dataset.localTimeFormat || "datetime"
    const options = this.optionsForFormat(format)

    try {
      el.textContent = new Intl.DateTimeFormat(undefined, options).format(date)
    } catch {
      // Keep the server-rendered fallback
    }
  }

  optionsForFormat(format) {
    switch (format) {
      case "time":
        return { hour: "numeric", minute: "2-digit" }
      case "date":
        return { month: "short", day: "numeric", year: "numeric" }
      case "short":
        return { month: "short", day: "numeric", hour: "numeric", minute: "2-digit" }
      case "datetime":
      default:
        return { month: "short", day: "numeric", year: "numeric", hour: "numeric", minute: "2-digit" }
    }
  }
}
