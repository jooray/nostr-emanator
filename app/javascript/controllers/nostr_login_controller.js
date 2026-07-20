import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["nip07Section", "divider", "extensionButton", "pollingIndicator", "errorMessage", "errorText", "config"]

  connect() {
    this.pollInterval = null
    this.checkNip07Extension()
    this.startPolling()
  }

  disconnect() {
    this.stopPolling()
  }

  checkNip07Extension() {
    if (typeof window.nostr !== "undefined") {
      this.nip07SectionTarget.classList.remove("hidden")
      this.dividerTarget.classList.remove("hidden")
    }
  }

  async loginWithExtension() {
    if (typeof window.nostr === "undefined") {
      this.showError("No NIP-07 extension found. Please install nos2x, Alby, or another Nostr extension.")
      return
    }

    this.stopPolling()
    this.extensionButtonTarget.disabled = true
    this.extensionButtonTarget.innerHTML = `
      <svg class="animate-spin h-5 w-5" viewBox="0 0 24 24">
        <circle class="opacity-25" cx="12" cy="12" r="10" stroke="currentColor" stroke-width="4" fill="none"/>
        <path class="opacity-75" fill="currentColor" d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4z"/>
      </svg>
      Connecting...
    `

    try {
      const pubkey = await window.nostr.getPublicKey()

      if (!pubkey) {
        this.showError("Failed to get public key from extension")
        this.resetButton()
        this.startPolling()
        return
      }

      const authEvent = {
        kind: 22242,
        created_at: Math.floor(Date.now() / 1000),
        tags: [
          ["challenge", this.configTarget.dataset.nostrLoginChallenge],
          ["domain", this.configTarget.dataset.nostrLoginDomain]
        ],
        content: "Sign in to Emanator"
      }

      const signedEvent = await window.nostr.signEvent(authEvent)

      const callbackUrl = this.configTarget.dataset.nostrLoginCallbackUrl
      const form = document.createElement("form")
      form.method = "post"
      form.action = callbackUrl
      const values = {
        authenticity_token: document.querySelector("meta[name='csrf-token']")?.content,
        pubkey: pubkey,
        signed_event: JSON.stringify(signedEvent)
      }
      Object.entries(values).forEach(([name, value]) => {
        const input = document.createElement("input")
        input.type = "hidden"
        input.name = name
        input.value = value || ""
        form.appendChild(input)
      })
      document.body.appendChild(form)
      form.submit()
    } catch (error) {
      console.error("NIP-07 login error:", error)
      this.showError(`Extension error: ${error.message || "Unknown error"}`)
      this.resetButton()
      this.startPolling()
    }
  }

  startPolling() {
    if (this.pollInterval) return
    const pollUrl = this.configTarget.dataset.nostrLoginPollUrl

    this.pollRequestInFlight = false

    this.pollInterval = setInterval(async () => {
      // M17: a first-login poll can take ~20s server-side (profile fetch);
      // without this guard the 3s ticker fires again while it's still in
      // flight, and overlapping polls can race find_or_create_user.
      if (this.pollRequestInFlight) return
      this.pollRequestInFlight = true

      this.pollAbortController = new AbortController()
      try {
        const response = await fetch(pollUrl, {
          method: "POST",
          headers: { "X-CSRF-Token": document.querySelector("meta[name='csrf-token']")?.content },
          signal: this.pollAbortController.signal
        })
        const data = await response.json()

        if (data.authenticated) {
          this.stopPolling()
          window.location.href = data.redirect_url
        } else if (data.expired) {
          this.stopPolling()
          this.showExpired()
        } else if (data.auth_url && data.auth_url !== this.authUrl) {
          this.authUrl = data.auth_url
          this.showAuthUrl(data.auth_url)
        }
      } catch (error) {
        if (error.name !== "AbortError") console.error("Polling error:", error)
      } finally {
        this.pollAbortController = null
        this.pollRequestInFlight = false
      }
    }, 3000)
  }

  stopPolling() {
    this.pollAbortController?.abort()
    this.pollAbortController = null
    if (this.pollInterval) {
      clearInterval(this.pollInterval)
      this.pollInterval = null
    }
  }

  showError(message) {
    this.errorMessageTarget.classList.remove("hidden")
    this.errorTextTarget.textContent = message
  }

  resetButton() {
    this.extensionButtonTarget.disabled = false
    this.extensionButtonTarget.innerHTML = `
      <svg class="h-5 w-5" fill="none" stroke="currentColor" viewBox="0 0 24 24">
        <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M13.828 10.172a4 4 0 00-5.656 0l-4 4a4 4 0 105.656 5.656l1.102-1.101m-.758-4.899a4 4 0 005.656 0l4-4a4 4 0 00-5.656-5.656l-1.1 1.1"/>
      </svg>
      Sign in with Browser Extension
    `
  }

  showAuthUrl(url) {
    this.errorMessageTarget.classList.remove("hidden")
    this.errorTextTarget.textContent = "Your signer requires additional authorization. "
    const link = document.createElement("a")
    link.href = url
    link.target = "_blank"
    link.rel = "noopener noreferrer"
    link.className = "font-medium underline"
    link.textContent = "Continue in signer"
    this.errorTextTarget.appendChild(link)
  }

  showExpired() {
    if (this.hasPollingIndicatorTarget) this.pollingIndicatorTarget.classList.add("hidden")

    this.errorMessageTarget.classList.remove("hidden")
    this.errorTextTarget.textContent = "QR expired — "
    const button = document.createElement("button")
    button.type = "button"
    button.className = "font-medium underline"
    button.textContent = "click to generate a new one"
    button.addEventListener("click", () => window.location.reload())
    this.errorTextTarget.appendChild(button)
  }
}
