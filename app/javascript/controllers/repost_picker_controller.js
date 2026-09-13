import { Controller } from "@hotwired/stimulus"

// The highest-consequence decision in the product, and it used to be the one
// with the least information attached.
//
// With nineteen paired identities this screen rendered eighteen unfiltered
// checkbox rows and a bare "Select All" — and every box ticked costs one Amber
// approval on the user's phone. Nobody was told that. The fastest path on the
// screen was one click to queue nineteen phone taps.
//
// So: filter the list (the account picker already proved the pattern), and
// state the consequence in approvals rather than in checkboxes.
export default class extends Controller {
  static targets = ["row", "checkbox", "filter", "readout", "selectAll", "empty"]

  connect() {
    this.report()
  }

  filter() {
    const q = this.filterTarget.value.trim().toLowerCase()
    let visible = 0

    this.rowTargets.forEach((row) => {
      const hit = !q || (row.dataset.search || "").includes(q)
      row.hidden = !hit
      if (hit) visible += 1
    })

    if (this.hasEmptyTarget) this.emptyTarget.hidden = visible > 0
  }

  // Select All applies to what is actually on screen. Ticking eighteen hidden
  // rows because a filter is active would be the same trap in a new place.
  toggleAll(event) {
    const on = event.currentTarget.checked
    this.rowTargets.forEach((row) => {
      if (row.hidden) return
      const box = row.querySelector("input[type=checkbox]")
      if (box) box.checked = on
    })
    this.report()
  }

  report() {
    const checked = this.checkboxTargets.filter((cb) => cb.checked).length
    if (!this.hasReadoutTarget) return

    if (checked === 0) {
      this.readoutTarget.textContent = "No reposts — one approval, for the post itself."
      this.readoutTarget.dataset.level = "quiet"
    } else {
      const approvals = checked + 1
      this.readoutTarget.textContent =
        `${checked} repost${checked === 1 ? "" : "s"} — ${approvals} separate approvals in your signer, one after another.`
      this.readoutTarget.dataset.level = approvals > 4 ? "loud" : "quiet"
    }
  }
}
