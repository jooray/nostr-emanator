import { Controller } from "@hotwired/stimulus"

// A signature can take up to two minutes of waiting for a human to tap Approve
// on a phone. Without an elapsed counter there is no way to tell "normal" from
// "dead" at t=45s, so the user either sits and stares or gives up on something
// that was about to work.
export default class extends Controller {
  static values = { start: String, limit: { type: Number, default: 120 } }
  static targets = ["readout", "note"]

  connect() {
    this.tick()
    this.timer = setInterval(() => this.tick(), 1000)
  }

  disconnect() {
    clearInterval(this.timer)
  }

  tick() {
    const started = Date.parse(this.startValue)
    if (Number.isNaN(started)) return

    const seconds = Math.max(0, Math.floor((Date.now() - started) / 1000))
    const mm = String(Math.floor(seconds / 60)).padStart(2, "0")
    const ss = String(seconds % 60).padStart(2, "0")
    if (this.hasReadoutTarget) this.readoutTarget.textContent = `${mm}:${ss}`

    // Past the signer's own window, stop implying it is still coming.
    if (this.hasNoteTarget && seconds > this.limitValue) {
      this.noteTarget.hidden = false
    }
  }
}
