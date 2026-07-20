import { Controller } from "@hotwired/stimulus"

// Auto-dismisses a flash notice/alert a few seconds after it appears — it
// used to sit on screen forever until the next navigation (L26).
export default class extends Controller {
  static values = { delay: { type: Number, default: 6000 } }

  connect() {
    this.timeout = setTimeout(() => this.dismiss(), this.delayValue)
  }

  disconnect() {
    clearTimeout(this.timeout)
  }

  dismiss() {
    this.element.classList.add("transition-opacity", "duration-500", "ease-out", "opacity-0")
    setTimeout(() => this.element.remove(), 500)
  }
}
