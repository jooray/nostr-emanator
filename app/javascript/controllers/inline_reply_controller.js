import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["form", "textarea", "status", "replyButton", "submitButton", "likeCheckbox", "followCheckbox", "refreshButton"]
  static values = {
    accountId: Number,
    eventId: String,
    authorPubkey: String,
    rootEventId: String,
    relayHint: { type: String, default: "" },
    alreadyFollowing: { type: Boolean, default: false }
  }

  connect() {
    this.hideRefreshButton()
  }

  toggle() {
    this.formTarget.classList.toggle("hidden")
    if (!this.formTarget.classList.contains("hidden")) {
      this.textareaTarget.focus()
      this.replyButtonTarget.classList.add("hidden")
    } else {
      this.replyButtonTarget.classList.remove("hidden")
      this.statusTarget.textContent = ""
      this.hideRefreshButton()
    }
  }

  async submit() {
    const content = this.textareaTarget.value.trim()
    if (!content) return

    this.submitButtonTarget.disabled = true
    this.textareaTarget.disabled = true
    this.statusTarget.textContent = "Creating reply..."
    this.statusTarget.className = "text-sm text-amber-600 dark:text-amber-400"

    try {
      const csrfToken = document.querySelector('meta[name="csrf-token"]')?.content
      const response = await fetch(`/accounts/${this.accountIdValue}/posts`, {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "Accept": "application/json",
          "X-CSRF-Token": csrfToken
        },
        body: JSON.stringify({
          post: {
            content: content,
            event_kind: 1,
            reply_to_event_id: this.eventIdValue,
            reply_to_pubkey: this.authorPubkeyValue,
            root_event_id: this.rootEventIdValue || this.eventIdValue,
            is_reply: true
          }
        })
      })

      const data = await response.json()

      if (data.success) {
        this.postId = data.post_id
        this.statusTarget.textContent = "Signing..."
        this.hideRefreshButton()
        this.fireSideEffects()
        this.pollStatus(data.post_id)
      } else {
        this.statusTarget.textContent = data.error || "Failed to create reply"
        this.statusTarget.className = "text-sm text-red-600 dark:text-red-400"
        this.submitButtonTarget.disabled = false
        this.textareaTarget.disabled = false
      }
    } catch (error) {
      this.statusTarget.textContent = "Network error. Please try again."
      this.statusTarget.className = "text-sm text-red-600 dark:text-red-400"
      this.submitButtonTarget.disabled = false
      this.textareaTarget.disabled = false
    }
  }

  async retry() {
    if (!this.postId) return

    try {
      this.statusTarget.textContent = "Retrying..."
      this.statusTarget.className = "text-sm text-amber-600 dark:text-amber-400"
      this.hideRefreshButton()

      const csrfToken = document.querySelector('meta[name="csrf-token"]')?.content
      const response = await fetch(`/posts/${this.postId}/retry_sign`, {
        method: "POST",
        headers: {
          "Accept": "application/json",
          "X-CSRF-Token": csrfToken
        }
      })

      const data = await response.json()

      if (!response.ok || !data.success) {
        this.statusTarget.textContent = data.error || "Retry failed. Open the post page to try again."
        this.statusTarget.className = "text-sm text-red-600 dark:text-red-400"
        this.showRefreshButton()
        return
      }

      this.pollStatus(this.postId)
    } catch (error) {
      this.statusTarget.textContent = "Retry failed. Please try again."
      this.statusTarget.className = "text-sm text-red-600 dark:text-red-400"
      this.showRefreshButton()
    }
  }

  fireSideEffects() {
    const actionsController = this.application.getControllerForElementAndIdentifier(
      this.element, "interaction-actions"
    )

    // Fire like if checkbox is checked
    if (this.hasLikeCheckboxTarget && this.likeCheckboxTarget.checked) {
      if (actionsController && !actionsController.alreadyLikedValue) {
        actionsController.like()
      }
    }

    // Fire follow if checkbox is checked
    if (this.hasFollowCheckboxTarget && this.followCheckboxTarget.checked) {
      if (actionsController && !actionsController.alreadyFollowingValue) {
        actionsController.follow()
      }
    }
  }

  pollStatus(postId) {
    clearInterval(this._pollInterval)
    this._pollInterval = setInterval(async () => {
      try {
        const response = await fetch(`/posts/${postId}.json`)
        const data = await response.json()

        switch (data.status) {
          case "awaiting_signature":
            this.statusTarget.textContent = "Signing... (approve in your signer app)"
            this.statusTarget.className = "text-sm text-amber-600 dark:text-amber-400"
            this.hideRefreshButton()
            break
          case "scheduled":
            this.statusTarget.textContent = "Publishing..."
            this.statusTarget.className = "text-sm text-amber-600 dark:text-amber-400"
            this.hideRefreshButton()
            break
          case "publishing":
            this.statusTarget.textContent = "Publishing..."
            this.statusTarget.className = "text-sm text-amber-600 dark:text-amber-400"
            this.hideRefreshButton()
            break
          case "published":
            clearInterval(this._pollInterval)
            this.statusTarget.textContent = "Reply published!"
            this.statusTarget.className = "text-sm text-green-600 dark:text-green-400"
            this.hideRefreshButton()
            this.textareaTarget.value = ""
            setTimeout(() => {
              this.formTarget.classList.add("hidden")
              this.replyButtonTarget.classList.remove("hidden")
              this.submitButtonTarget.disabled = false
              this.textareaTarget.disabled = false
              this.statusTarget.textContent = ""
            }, 2000)
            break
          case "failed":
            clearInterval(this._pollInterval)
            if (data.unsigned_event_present && !data.signed_event_present) {
              this.statusTarget.textContent = "Signing stalled. Retry to try again."
              this.statusTarget.className = "text-sm text-red-600 dark:text-red-400"
              this.showRefreshButton()
            } else {
              this.statusTarget.textContent = "Publishing failed. Please try again from the post page."
              this.statusTarget.className = "text-sm text-red-600 dark:text-red-400"
              this.hideRefreshButton()
            }
            this.submitButtonTarget.disabled = false
            this.textareaTarget.disabled = false
            break
        }
      } catch (error) {
        // Silently retry on network error
      }
    }, 2000)
  }

  disconnect() {
    if (this._pollInterval) {
      clearInterval(this._pollInterval)
    }
  }

  showRefreshButton() {
    // The account-page "recent interactions" partial doesn't render a
    // refreshButton target (only the main Interactions page card does) —
    // guard so connect()/submit()/pollStatus() never throw there.
    if (!this.hasRefreshButtonTarget) return
    this.refreshButtonTarget.classList.remove("hidden")
    this.refreshButtonTarget.classList.add("inline-flex")
  }

  hideRefreshButton() {
    if (!this.hasRefreshButtonTarget) return
    this.refreshButtonTarget.classList.add("hidden")
    this.refreshButtonTarget.classList.remove("inline-flex")
  }
}
