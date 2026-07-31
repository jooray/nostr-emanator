import { Controller } from "@hotwired/stimulus"

// Enter sends, Shift+Enter makes a newline — the convention every chat UI uses.
//
// Only wired to the NIP-17 composer. The legacy and downgrade forms deliberately
// require clicking their own clearly-labelled button, so a downgrade can never be
// sent by muscle memory.
export default class extends Controller {
  static targets = ["input"]

  maybeSend(event) {
    if (event.key !== "Enter" || event.shiftKey) return
    // Let IME composition finish before treating Enter as send.
    if (event.isComposing) return
    if (!this.inputTarget.value.trim()) return

    event.preventDefault()
    this.element.requestSubmit()
  }
}
