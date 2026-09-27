import { Controller } from "@hotwired/stimulus"

// Enter sends, Shift+Enter makes a newline — the convention every chat UI uses.
//
// Enter-to-send is only wired to the NIP-17 composer. The legacy and downgrade
// forms use this controller just for #clear: they deliberately require clicking
// their own clearly-labelled button, so a downgrade can never be sent by muscle
// memory.
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

  // Once the server has accepted the message it exists as its own bubble, which
  // carries "Try again" if signing or delivery later fails — so the text no
  // longer belongs in the box. Without this, the page's morph refresh keeps the
  // focused textarea's value (Turbo morphs with ignoreActiveValue) and the sent
  // message sits there waiting to be sent twice. A network error or 5xx leaves
  // the text alone, since nothing was saved.
  clear(event) {
    if (!event.detail.success) return
    this.inputTarget.value = ""
  }
}
