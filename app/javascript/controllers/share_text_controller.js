import { Controller } from "@hotwired/stimulus"
import { t } from "../lib/i18n"
import { copyText, legacyCopy } from "../lib/clipboard"

// Facebook and LinkedIn, from the web: neither offers a URL that accepts a
// post's text (their share endpoints take a link, and a note is not a link), so
// this copies the note and opens the network's composer — one paste away.
// The Android app shares the text straight into the installed app instead.
export default class extends Controller {
  static values = { text: String, url: String }

  share() {
    // Opened first: a window.open after an await is treated as a popup.
    window.open(this.urlValue, "_blank", "noopener")
    this.copy()
  }

  async copy() {
    try {
      await copyText(this.textValue)
      this.flash(t("js.share_text.copied"))
    } catch {
      try {
        legacyCopy(this.textValue)
        this.flash(t("js.share_text.copied"))
      } catch {
        console.error("Copy to clipboard failed")
        this.flash(t("js.share_text.copy_failed"))
      }
    }
  }

  flash(message) {
    const original = this.element.textContent
    this.element.textContent = message
    setTimeout(() => { this.element.textContent = original }, 2000)
  }
}
