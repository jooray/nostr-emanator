import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["status", "form"]
  static values = { pollUrl: String, rePair: { type: Boolean, default: false } }

  connect() {
    this.pollInterval = null
    this.startPolling()
  }

  disconnect() {
    this.stopPolling()
  }

  startPolling() {
    if (!this.pollUrlValue) return

    this.pollInterval = setInterval(async () => {
      try {
        const response = await fetch(this.pollUrlValue, {
          method: "POST",
          headers: { "X-CSRF-Token": document.querySelector("meta[name='csrf-token']")?.content }
        })
        const data = await response.json()

        if (data.paired) {
          this.stopPolling()
          this.onPaired(data)
        } else if (data.error) {
          this.stopPolling()
          this.onError(data.error)
        } else if (data.auth_url && data.auth_url !== this.authUrl) {
          this.authUrl = data.auth_url
          this.showAuthUrl(data.auth_url)
        }
      } catch (error) {
        console.error("Pairing poll error:", error)
      }
    }, 2000)
  }

  stopPolling() {
    if (this.pollInterval) {
      clearInterval(this.pollInterval)
      this.pollInterval = null
    }
  }

  onError(message) {
    if (this.hasStatusTarget) {
      this.statusTarget.innerHTML = `
        <div class="flex items-center gap-2 text-red-600 dark:text-red-400">
          <svg class="h-5 w-5 flex-shrink-0" fill="none" stroke="currentColor" viewBox="0 0 24 24">
            <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M12 9v2m0 4h.01M21 12a9 9 0 11-18 0 9 9 0 0118 0z"/>
          </svg>
          <span class="text-sm">${message}</span>
        </div>
      `
    }
  }

  showAuthUrl(url) {
    if (!this.hasStatusTarget) return

    this.statusTarget.textContent = "Your signer requires additional authorization. "
    const link = document.createElement("a")
    link.href = url
    link.target = "_blank"
    link.rel = "noopener noreferrer"
    link.className = "font-medium text-amber-600 dark:text-amber-400 underline"
    link.textContent = "Continue in signer"
    this.statusTarget.appendChild(link)
  }

  onPaired(data) {
    if (this.hasStatusTarget) {
      this.statusTarget.innerHTML = `
        <div class="flex items-center gap-2 text-green-600 dark:text-green-400">
          <svg class="h-5 w-5" fill="none" stroke="currentColor" viewBox="0 0 24 24">
            <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M5 13l4 4L19 7"/>
          </svg>
          <span class="text-sm font-medium">${this.rePairValue ? "Signer re-paired!" : "Account paired! Creating..."}</span>
        </div>
      `
    }

    // For re-pair, the server already updated the account — just redirect
    if (this.rePairValue && data.redirect_url) {
      window.location.href = data.redirect_url
      return
    }

    // POST to /accounts — server retrieves signer data from session
    const csrfToken = document.querySelector("meta[name='csrf-token']")?.content

    fetch("/accounts", {
      method: "POST",
      headers: {
        "X-CSRF-Token": csrfToken,
        "Accept": "text/html"
      },
      redirect: "follow"
    }).then(response => {
      if (response.redirected) {
        window.location.href = response.url
      } else {
        window.location.href = "/accounts"
      }
    })
  }
}
