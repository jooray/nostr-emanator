import { Controller } from "@hotwired/stimulus"
import { t } from "../lib/i18n"
import { copyText, legacyCopy } from "../lib/clipboard"

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
      await copyText(text)
      this.flash(t("js.clipboard.copied"))
    } catch (error) {
      // copyText can reject (permissions prompt denied, insecure context, focus
      // lost, etc.) — fall back to the legacy execCommand path instead of
      // leaving an unhandled rejection.
      try {
        legacyCopy(text)
        this.flash(t("js.clipboard.copied"))
      } catch (fallbackError) {
        console.error("Copy to clipboard failed:", fallbackError)
        this.flash(t("js.clipboard.copy_failed"))
      }
    }
  }

  flash(message) {
    const original = this.element.textContent
    this.element.textContent = message
    setTimeout(() => { this.element.textContent = original }, 1500)
  }
}
