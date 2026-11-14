import { Controller } from "@hotwired/stimulus"

// A <details> used as a menu: closes on a click outside it or on Escape, and
// opening one closes any other open menu.
export default class extends Controller {
  connect() {
    this.outside = (event) => { if (!this.element.contains(event.target)) this.element.open = false }
    this.escape = (event) => { if (event.key === "Escape") this.element.open = false }
    this.toggled = () => {
      if (!this.element.open) return
      document.querySelectorAll("details[data-controller~='dropdown'][open]").forEach((other) => {
        if (other !== this.element) other.open = false
      })
    }
    document.addEventListener("click", this.outside)
    document.addEventListener("keydown", this.escape)
    this.element.addEventListener("toggle", this.toggled)
  }

  disconnect() {
    document.removeEventListener("click", this.outside)
    document.removeEventListener("keydown", this.escape)
    this.element.removeEventListener("toggle", this.toggled)
  }
}
