import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["input", "row", "empty"]

  connect() {
    if (this.hasInputTarget) this.inputTarget.focus()
    this.filter()
  }

  filter() {
    const query = this.hasInputTarget ? this.inputTarget.value.trim().toLowerCase() : ""
    let visible = 0
    this.rowTargets.forEach(row => {
      const text = row.dataset.searchText || ""
      const match = query === "" || text.includes(query)
      row.classList.toggle("hidden", !match)
      if (match) visible += 1
    })
    if (this.hasEmptyTarget) {
      this.emptyTarget.classList.toggle("hidden", visible > 0)
    }
  }

  submit(event) {
    event.preventDefault()
    const first = this.rowTargets.find(row => !row.classList.contains("hidden"))
    if (first) first.click()
  }
}
