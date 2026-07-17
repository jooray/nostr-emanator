import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  connect() {
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
