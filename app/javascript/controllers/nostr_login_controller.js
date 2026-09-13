import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = [
    "nip07Section", "extensionButton", "extensionButtonLabel",
    "pollingIndicator", "pollingLabel",
    "errorMessage", "errorText", "config", "qrSection",
    "expiredNotice", "staleNotice",
    "bunkerSection", "bunkerInput", "bunkerButton",
    "authChallenge", "authChallengeLink"
  ]

  connect() {
    this.pollInterval = null
    this.checkNip07Extension()
    this.watchForegroundReturn()
    this.startPolling()
  }

  disconnect() {
    this.stopPolling()
    if (this.nip07Timer) clearInterval(this.nip07Timer)
    if (this.staleTimer) clearTimeout(this.staleTimer)
    if (this.visibilityHandler) {
      document.removeEventListener("visibilitychange", this.visibilityHandler)
    }
  }

  // Extensions inject window.nostr asynchronously, so a single check on connect
  // misses the ones that are a little slow and the button never appears at all.
  checkNip07Extension() {
    if (this.revealExtension()) return

    let waited = 0
    this.nip07Timer = setInterval(() => {
      waited += 150
      if (this.revealExtension() || waited >= 3000) clearInterval(this.nip07Timer)
    }, 150)
  }

  revealExtension() {
    if (typeof window.nostr === "undefined") return false
    this.nip07SectionTarget.classList.remove("hidden")
    return true
  }

  // A mobile browser may suspend this page while the signer app is in the
  // foreground. The nostrconnect reply is an ephemeral event that cannot be
  // replayed, so a missed one is unrecoverable: after coming back, give it a
  // moment and then offer a fresh code instead of spinning indefinitely.
  watchForegroundReturn() {
    this.visibilityHandler = () => {
      if (document.visibilityState !== "visible") return
      if (!this.pollInterval) return
      if (this.staleTimer) clearTimeout(this.staleTimer)
      this.staleTimer = setTimeout(() => {
        if (this.pollInterval && this.hasStaleNoticeTarget) {
          this.staleNoticeTarget.classList.remove("hidden")
        }
      }, 3000)
    }
    document.addEventListener("visibilitychange", this.visibilityHandler)
  }

  // bunker://: the user pastes a link naming their signer and we speak first.
  async connectBunker(event) {
    if (event) event.preventDefault()

    const uri = this.bunkerInputTarget.value.trim()
    if (!uri) {
      this.showError("Paste the bunker link from your signer first.")
      return
    }

    this.hideError()
    this.bunkerButtonTarget.disabled = true
    const originalLabel = this.bunkerButtonTarget.textContent
    this.bunkerButtonTarget.textContent = "Connecting…"

    try {
      const response = await fetch(this.configTarget.dataset.nostrLoginBunkerUrl, {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "X-CSRF-Token": document.querySelector("meta[name='csrf-token']")?.content
        },
        body: JSON.stringify({ bunker_uri: uri })
      })
      const data = await response.json()

      if (!data.ok) {
        this.showError(data.error || "Could not use that bunker link.")
        return
      }

      // The server replaced this browser's pending session, so any notice from
      // the previous one is stale. Resume polling against the new one.
      if (this.hasStaleNoticeTarget) this.staleNoticeTarget.classList.add("hidden")
      if (this.hasExpiredNoticeTarget) this.expiredNoticeTarget.classList.add("hidden")
      if (this.hasPollingIndicatorTarget) this.pollingIndicatorTarget.classList.remove("hidden")
      if (this.hasPollingLabelTarget) this.pollingLabelTarget.textContent = "Waiting for your signer to approve…"
      this.stopPolling()
      this.startPolling()
    } catch (error) {
      console.error("Bunker connect error:", error)
      this.showError("Could not reach the server. Check your connection and try again.")
    } finally {
      this.bunkerButtonTarget.disabled = false
      this.bunkerButtonTarget.textContent = originalLabel
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

    // The approval window is 5 minutes; polling past it can never succeed, so
    // cap the attempts as a backstop even if the server never says "expired".
    const maxAttempts = Math.ceil((10 * 60 * 1000) / 3000)
    let attempts = 0
    let consecutiveErrors = 0

    this.pollInterval = setInterval(async () => {
      if (++attempts > maxAttempts) {
        this.showExpired()
        return
      }

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
        consecutiveErrors = 0

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
        if (error.name !== "AbortError") {
          console.error("Polling error:", error)
          if (++consecutiveErrors >= 5) {
            this.stopPolling()
            this.showError("Lost connection to the server. Please reload the page to try again.")
          }
        }
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

  // A signer demanding browser authorization is not an error, so it gets its
  // own panel rather than the red error box.
  showAuthUrl(url) {
    if (!this.hasAuthChallengeTarget) return
    this.authChallengeLinkTarget.href = url
    this.authChallengeTarget.classList.remove("hidden")
  }

  showExpired() {
    this.stopPolling()

    if (this.hasPollingIndicatorTarget) this.pollingIndicatorTarget.classList.add("hidden")
    if (this.hasQrSectionTarget) this.qrSectionTarget.classList.add("hidden")
    // The stale hint and the expired notice both offer a fresh code; showing
    // both at once just says the same thing twice.
    if (this.hasStaleNoticeTarget) this.staleNoticeTarget.classList.add("hidden")
    if (this.hasAuthChallengeTarget) this.authChallengeTarget.classList.add("hidden")
    if (this.hasExpiredNoticeTarget) this.expiredNoticeTarget.classList.remove("hidden")
    // The bunker section deliberately stays: pasting a link mints a brand new
    // session, so it is a working way out of an expired code.
  }
}
