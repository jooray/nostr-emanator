import { Controller } from "@hotwired/stimulus"

// Resolves the composer's "checking where this person receives messages" state
// on its own, so the user never has to reload to find out.
//
// The server cannot answer immediately: working out whether a peer has published
// a kind 10050 means querying indexer relays and their own NIP-65 write relays,
// which belongs in a background job rather than in the request. So the frame
// re-renders itself until the answer lands.
//
// The controller lives INSIDE the frame. When the frame swaps, this instance
// disconnects (clearing its timer) and the replacement connects with the new
// state — so a resolved composer simply never starts a timer.
export default class extends Controller {
  static values = { checking: Boolean, url: String }
  static targets = ["status"]

  // The lookup is a couple of relay round-trips; anything faster just adds load.
  static INTERVAL = 2500
  // Give up after ~1 minute. A relay set that has not answered by then is not
  // about to, and a page left open overnight must not poll forever.
  static MAX_ATTEMPTS = 24

  connect() {
    if (!this.checkingValue) return

    this.attempts = 0
    this.timer = setInterval(() => this.refresh(), this.constructor.INTERVAL)
  }

  disconnect() {
    if (this.timer) clearInterval(this.timer)
  }

  async refresh() {
    if (++this.attempts > this.constructor.MAX_ATTEMPTS) return this.giveUp()

    try {
      const response = await fetch(this.urlValue, {
        headers: { Accept: "text/html" },
        credentials: "same-origin"
      })
      if (!response.ok) return

      // The endpoint returns the body without a frame wrapper, so this replaces
      // the frame's contents. Swapping the element disconnects this controller
      // and connects a fresh one carrying the new state — which is what stops the
      // polling once the answer arrives.
      this.element.outerHTML = await response.text()
    } catch {
      // A transient network error is not worth surfacing; the next tick retries.
    }
  }

  giveUp() {
    clearInterval(this.timer)
    if (!this.hasStatusTarget) return

    this.statusTarget.textContent =
      "Could not work out where this person receives private messages. Reload to try again."
  }
}
