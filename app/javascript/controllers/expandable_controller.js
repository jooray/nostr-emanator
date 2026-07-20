import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["content", "toggle"]

  connect() {
    this.expanded = false
    this.evaluateOverflow()

    this.resizeObserver = new ResizeObserver(() => this.evaluateOverflow())
    this.resizeObserver.observe(this.contentTarget)

    this.imageLoadHandler = () => this.evaluateOverflow()
    this.contentTarget.querySelectorAll("img").forEach(img => {
      img.addEventListener("load", this.imageLoadHandler)
    })
  }

  disconnect() {
    if (this.resizeObserver) this.resizeObserver.disconnect()
    if (this.imageLoadHandler) {
      this.contentTarget.querySelectorAll("img").forEach(img => {
        img.removeEventListener("load", this.imageLoadHandler)
      })
    }
  }

  evaluateOverflow() {
    if (!this.hasContentTarget || !this.hasToggleTarget) return
    if (this.expanded) return

    const overflows = this.contentTarget.scrollHeight > this.contentTarget.clientHeight + 1
    this.toggleTarget.classList.toggle("hidden", !overflows)
  }

  toggle() {
    this.expanded = !this.expanded
    this.contentTarget.classList.toggle("line-clamp-3", !this.expanded)
    this.contentTarget.classList.toggle("line-clamp-6", false)
    this.toggleTarget.textContent = this.expanded ? "Show less" : "Show more"
    if (!this.expanded) this.evaluateOverflow()
  }
}
