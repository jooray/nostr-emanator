import { Controller } from "@hotwired/stimulus"

// A <details> used as a menu: closes on a click outside it or on Escape, and
// opening one closes any other open menu. With an `input` target it is a
// searchable list (shared/_account_menu): opening focuses the box, typing
// filters the `row` targets by their data-search-text, Enter takes the first
// row still shown.
export default class extends Controller {
  static targets = ["input", "row", "empty"]

  connect() {
    this.outside = (event) => { if (!this.element.contains(event.target)) this.element.open = false }
    this.escape = (event) => { if (event.key === "Escape" && this.element.open) this.close() }
    this.toggled = () => {
      if (!this.element.open) return
      document.querySelectorAll("details[data-controller~='dropdown'][open]").forEach((other) => {
        if (other !== this.element) other.open = false
      })
      if (this.hasInputTarget) {
        this.inputTarget.value = ""
        this.filter()
        this.inputTarget.focus()
      }
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

  filter() {
    const query = this.inputTarget.value.trim().toLowerCase()
    let shown = 0
    this.rowTargets.forEach((row) => {
      const match = query === "" || (row.dataset.searchText || "").includes(query)
      row.classList.toggle("hidden", !match)
      if (match) shown += 1
    })
    if (this.hasEmptyTarget) this.emptyTarget.classList.toggle("hidden", shown > 0)
  }

  pick(event) {
    event.preventDefault()
    const first = this.rowTargets.find((row) => !row.classList.contains("hidden"))
    first?.querySelector("a, button")?.click()
  }

  close() {
    this.element.open = false
    this.element.querySelector("summary")?.focus()
  }
}
