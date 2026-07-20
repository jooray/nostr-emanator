import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static values = { text: String }

  // Used for readonly "click to select" inputs (e.g. a freshly generated API
  // token) instead of an inline onclick="this.select()" attribute, which a
  // strict Content-Security-Policy script-src blocks (M2).
  selectAll(event) {
    event.target.select()
  }

  async copy() {
    const text = this.textValue

    try {
      if (navigator.clipboard?.writeText) {
        await navigator.clipboard.writeText(text)
      } else {
        this.legacyCopy(text)
      }
      this.flash("Copied!")
    } catch (error) {
      // navigator.clipboard.writeText can reject (permissions prompt denied,
      // insecure context, focus lost, etc.) — fall back to the legacy
      // execCommand path instead of leaving an unhandled rejection.
      try {
        this.legacyCopy(text)
        this.flash("Copied!")
      } catch (fallbackError) {
        console.error("Copy to clipboard failed:", fallbackError)
        this.flash("Copy failed")
      }
    }
  }

  legacyCopy(text) {
    const textarea = document.createElement("textarea")
    textarea.value = text
    textarea.style.position = "fixed"
    textarea.style.opacity = "0"
    document.body.appendChild(textarea)
    textarea.focus()
    textarea.select()
    const succeeded = document.execCommand("copy")
    textarea.remove()
    if (!succeeded) throw new Error("execCommand('copy') failed")
  }

  flash(message) {
    const original = this.element.textContent
    this.element.textContent = message
    setTimeout(() => { this.element.textContent = original }, 1500)
  }
}
