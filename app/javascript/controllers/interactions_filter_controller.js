import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["toggleAllButton", "accountButton", "content"]
  static values = { accountIds: Array }

  connect() {
    this.selectedIds = new Set(this.accountIdsValue.map(String))
    this.updateUI()
    this.applyFilter()
    this.observeContent()
  }

  disconnect() {
    if (this.observer) {
      this.observer.disconnect()
      this.observer = null
    }
  }

  observeContent() {
    if (!this.hasContentTarget) return
    if (this.observer) this.observer.disconnect()

    this.observer = new MutationObserver(() => this.applyFilter())
    this.observer.observe(this.contentTarget, { childList: true, subtree: true })
  }

  contentTargetConnected() {
    this.applyFilter()
    this.observeContent()
  }

  toggleAll() {
    if (this.selectedIds.size === this.accountIdsValue.length) {
      this.selectedIds.clear()
    } else {
      this.selectedIds = new Set(this.accountIdsValue.map(String))
    }
    this.applyFilter()
    this.updateUI()
  }

  toggleAccount(event) {
    const id = String(event.currentTarget.dataset.accountId)
    if (this.selectedIds.has(id)) {
      this.selectedIds.delete(id)
    } else {
      this.selectedIds.add(id)
    }
    this.applyFilter()
    this.updateUI()
  }

  applyFilter() {
    if (!this.hasContentTarget || !this.selectedIds) return

    const cards = this.contentTarget.querySelectorAll("[data-account-id]")
    cards.forEach(card => {
      const cardAccountId = card.dataset.accountId
      card.style.display = this.selectedIds.has(cardAccountId) ? "" : "none"
    })
  }

  updateUI() {
    const allSelected = this.selectedIds.size === this.accountIdsValue.length

    if (this.hasToggleAllButtonTarget) {
      this.toggleAllButtonTarget.textContent = allSelected ? "Unselect All" : "Select All"
    }

    this.accountButtonTargets.forEach(btn => {
      const id = String(btn.dataset.accountId)
      const active = this.selectedIds.has(id)
      btn.classList.toggle("bg-amber-100", active)
      btn.classList.toggle("text-amber-800", active)
      btn.classList.toggle("dark:bg-amber-900", active)
      btn.classList.toggle("dark:text-amber-200", active)
      btn.classList.toggle("bg-gray-100", !active)
      btn.classList.toggle("text-gray-700", !active)
      btn.classList.toggle("dark:bg-gray-700", !active)
      btn.classList.toggle("dark:text-gray-300", !active)
    })
  }
}
