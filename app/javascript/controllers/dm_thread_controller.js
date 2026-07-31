import { Controller } from "@hotwired/stimulus"

// Keeps a message thread pinned to the newest message, the way every chat UI
// does, without fighting a user who has scrolled up to read history.
export default class extends Controller {
  static targets = ["scroll"]

  connect() {
    this.scrollToBottom()

    // New messages arrive by Turbo Stream, so watch for appended nodes rather
    // than only scrolling on load.
    this.observer = new MutationObserver(() => {
      if (this.wasAtBottom) this.scrollToBottom()
    })
    this.observer.observe(this.scrollTarget, { childList: true, subtree: true })

    this.wasAtBottom = true
    this.trackScroll = () => { this.wasAtBottom = this.atBottom() }
    this.scrollTarget.addEventListener("scroll", this.trackScroll, { passive: true })
  }

  disconnect() {
    this.observer?.disconnect()
    this.scrollTarget?.removeEventListener("scroll", this.trackScroll)
  }

  scrollToBottom() {
    this.scrollTarget.scrollTop = this.scrollTarget.scrollHeight
  }

  // 40px of slack, so "almost at the bottom" still counts as following along.
  atBottom() {
    const el = this.scrollTarget
    return el.scrollHeight - el.scrollTop - el.clientHeight < 40
  }
}
