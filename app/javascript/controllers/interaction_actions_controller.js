import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["likeButton", "followButton", "muteButton", "likeStatus", "followStatus", "muteStatus", "likeRefreshButton", "followRefreshButton", "muteRefreshButton"]
  static values = {
    accountId: Number,
    eventId: String,
    authorPubkey: String,
    targetEventKind: { type: Number, default: 1 },
    relayHint: { type: String, default: "" },
    alreadyFollowing: { type: Boolean, default: false },
    alreadyLiked: { type: Boolean, default: false }
  }

  connect() {
    this.actionIds = {}
    this.hideRefreshButton("like")
    this.hideRefreshButton("follow")
    this.hideRefreshButton("mute")
    if (this.alreadyLikedValue) this.setLiked()
    if (this.alreadyFollowingValue) this.setFollowed()
  }

  async like() {
    if (this.alreadyLikedValue) return
    this.alreadyLikedValue = true
    this.setLiked()

    try {
      const data = await this.createAction({
        action_type: "reaction",
        target_event_id: this.eventIdValue,
        target_pubkey: this.authorPubkeyValue,
        target_event_kind: this.targetEventKindValue
      })

      if (data.success) {
        this.actionIds.like = data.nostr_action_id
        this.showStatus("likeStatus", "Signing...", "amber")
        this.hideRefreshButton("like")
        this.pollActionStatus(data.nostr_action_id, "like")
      } else {
        this.showStatus("likeStatus", data.error || "Failed", "red")
        this.hideRefreshButton("like")
        this.alreadyLikedValue = false
        this.unsetLiked()
      }
    } catch {
      this.showStatus("likeStatus", "Network error", "red")
      this.hideRefreshButton("like")
      this.alreadyLikedValue = false
      this.unsetLiked()
    }
  }

  async follow() {
    if (this.alreadyFollowingValue) return
    this.alreadyFollowingValue = true
    this.setFollowed()

    try {
      const data = await this.createAction({
        action_type: "follow",
        target_pubkey: this.authorPubkeyValue
      })

      if (data.success) {
        this.actionIds.follow = data.nostr_action_id
        if (data.status === "published") {
          this.showStatus("followStatus", "Already following", "green")
          this.hideRefreshButton("follow")
          this.clearStatusAfter("followStatus", 3000)
        } else {
          this.showStatus("followStatus", "Signing...", "amber")
          this.hideRefreshButton("follow")
          this.pollActionStatus(data.nostr_action_id, "follow")
        }
      } else {
        this.showStatus("followStatus", data.error || "Failed", "red")
        this.hideRefreshButton("follow")
        this.alreadyFollowingValue = false
        this.unsetFollowed()
      }
    } catch {
      this.showStatus("followStatus", "Network error", "red")
      this.hideRefreshButton("follow")
      this.alreadyFollowingValue = false
      this.unsetFollowed()
    }
  }

  async mute() {
    const label = this.muteTargetLabel()
    if (!confirm(`Mute ${label}? Their posts will be hidden across all your accounts.`)) return

    this.showStatus("muteStatus", "Muting...", "amber")
    this.hideRefreshButton("mute")

    try {
      const data = await this.createAction({
        action_type: "mute",
        target_pubkey: this.authorPubkeyValue
      })

      if (data.success) {
        this.actionIds.mute = data.nostr_action_id
        if (data.status === "published") {
          this.hideCardsForAuthor()
        } else {
          this.showStatus("muteStatus", "Signing...", "amber")
          this.pollActionStatus(data.nostr_action_id, "mute")
        }
      } else {
        this.showStatus("muteStatus", data.error || "Failed", "red")
      }
    } catch {
      this.showStatus("muteStatus", "Network error", "red")
    }
  }

  retryLike() {
    this.retryAction("like")
  }

  retryFollow() {
    this.retryAction("follow")
  }

  retryMute() {
    this.retryAction("mute")
  }

  hideCardsForAuthor() {
    const selector = `[data-author-pubkey="${this.authorPubkeyValue}"]`
    document.querySelectorAll(selector).forEach(el => el.remove())
  }

  muteTargetLabel() {
    // Prefer the visible label on the Mute button itself (author's name or
    // truncated pubkey), falling back to the pubkey value. Keeps the confirm
    // dialog aligned with what the user sees.
    const span = this.hasMuteButtonTarget ? this.muteButtonTarget.querySelector("span") : null
    return span?.textContent?.trim() || `@${this.authorPubkeyValue.slice(0, 12)}`
  }

  setLiked() {
    if (!this.hasLikeButtonTarget) return
    this.likeButtonTarget.innerHTML = `
      <svg class="h-4 w-4" fill="currentColor" viewBox="0 0 24 24">
        <path d="M11.645 20.91l-.007-.003-.022-.012a15.247 15.247 0 01-.383-.218 25.18 25.18 0 01-4.244-3.17C4.688 15.36 2.25 12.174 2.25 8.25 2.25 5.322 4.714 3 7.688 3A5.5 5.5 0 0112 5.052 5.5 5.5 0 0116.313 3c2.973 0 5.437 2.322 5.437 5.25 0 3.925-2.438 7.111-4.739 9.256a25.175 25.175 0 01-4.244 3.17 15.247 15.247 0 01-.383.219l-.022.012-.007.004-.003.001a.752.752 0 01-.704 0l-.003-.001z"/>
      </svg>`
    this.likeButtonTarget.classList.add("text-red-500", "dark:text-red-400")
    this.likeButtonTarget.classList.remove("text-gray-400", "dark:text-gray-500", "hover:text-red-500", "dark:hover:text-red-400")
    this.likeButtonTarget.disabled = true
  }

  unsetLiked() {
    if (!this.hasLikeButtonTarget) return
    this.likeButtonTarget.innerHTML = `
      <svg class="h-4 w-4" fill="none" stroke="currentColor" viewBox="0 0 24 24">
        <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M4.318 6.318a4.5 4.5 0 000 6.364L12 20.364l7.682-7.682a4.5 4.5 0 00-6.364-6.364L12 7.636l-1.318-1.318a4.5 4.5 0 00-6.364 0z"/>
      </svg>`
    this.likeButtonTarget.classList.remove("text-red-500", "dark:text-red-400")
    this.likeButtonTarget.classList.add("text-gray-400", "dark:text-gray-500", "hover:text-red-500", "dark:hover:text-red-400")
    this.likeButtonTarget.disabled = false
  }

  setFollowed() {
    if (!this.hasFollowButtonTarget) return
    this.followButtonTarget.innerHTML = `
      <svg class="h-4 w-4" fill="none" stroke="currentColor" viewBox="0 0 24 24">
        <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M5 13l4 4L19 7"/>
      </svg>
      <span>Following</span>`
    this.followButtonTarget.classList.add("text-green-500", "dark:text-green-400")
    this.followButtonTarget.classList.remove("text-gray-400", "dark:text-gray-500", "hover:text-amber-500", "dark:hover:text-amber-400")
    this.followButtonTarget.disabled = true
  }

  unsetFollowed() {
    if (!this.hasFollowButtonTarget) return
    this.followButtonTarget.innerHTML = `
      <svg class="h-4 w-4" fill="none" stroke="currentColor" viewBox="0 0 24 24">
        <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M18 9v3m0 0v3m0-3h3m-3 0h-3m-2-5a4 4 0 11-8 0 4 4 0 018 0zM3 20a6 6 0 0112 0v1H3v-1z"/>
      </svg>
      <span>Follow</span>`
    this.followButtonTarget.classList.remove("text-green-500", "dark:text-green-400")
    this.followButtonTarget.classList.add("text-gray-400", "dark:text-gray-500", "hover:text-amber-500", "dark:hover:text-amber-400")
    this.followButtonTarget.disabled = false
  }

  pollActionStatus(actionId, type) {
    const statusTarget = this.statusTargetName(type)
    this._pollIntervals = this._pollIntervals || {}
    this.actionIds[type] = actionId
    clearInterval(this._pollIntervals[type])

    this._pollIntervals[type] = setInterval(async () => {
      try {
        const response = await fetch(`/nostr_actions/${actionId}.json`)
        const data = await response.json()

        switch (data.status) {
          case "pending":
          case "processing":
            this.showStatus(statusTarget, "Processing...", "amber")
            this.hideRefreshButton(type)
            break
          case "awaiting_signature":
            this.showStatus(statusTarget, "Approve in signer app...", "amber")
            this.hideRefreshButton(type)
            break
          case "publishing":
            this.showStatus(statusTarget, "Publishing...", "amber")
            this.hideRefreshButton(type)
            break
          case "published":
            clearInterval(this._pollIntervals[type])
            this.hideRefreshButton(type)
            if (type === "like") {
              this.showStatus(statusTarget, "Liked!", "green")
              this.clearStatusAfter(statusTarget, 3000)
            } else if (type === "follow") {
              this.showStatus(statusTarget, "Followed!", "green")
              this.clearStatusAfter(statusTarget, 3000)
            } else if (type === "mute") {
              this.hideCardsForAuthor()
            }
            break
          case "failed":
            clearInterval(this._pollIntervals[type])
            this.showStatus(statusTarget, data.error_message || "Failed", "red")
            if (data.unsigned_event_present && !data.signed_event_present) {
              this.showRefreshButton(type)
            } else {
              this.hideRefreshButton(type)
              if (type === "like") {
                this.alreadyLikedValue = false
                this.unsetLiked()
              } else if (type === "follow") {
                this.alreadyFollowingValue = false
                this.unsetFollowed()
              }
            }
            break
        }
      } catch {
        // Silently retry on network error
      }
    }, 2000)
  }

  statusTargetName(type) {
    switch (type) {
      case "like": return "likeStatus"
      case "follow": return "followStatus"
      case "mute": return "muteStatus"
      default: return "likeStatus"
    }
  }

  async createAction(params) {
    const csrfToken = document.querySelector('meta[name="csrf-token"]')?.content
    const response = await fetch(`/accounts/${this.accountIdValue}/nostr_actions`, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "Accept": "application/json",
        "X-CSRF-Token": csrfToken
      },
      body: JSON.stringify({ nostr_action: params })
    })
    return response.json()
  }

  async retryAction(type) {
    const actionId = this.actionIds[type]
    const statusTarget = this.statusTargetName(type)

    if (!actionId) return

    try {
      this.showStatus(statusTarget, "Retrying...", "amber")
      this.hideRefreshButton(type)

      const csrfToken = document.querySelector('meta[name="csrf-token"]')?.content
      const response = await fetch(`/nostr_actions/${actionId}/retry`, {
        method: "POST",
        headers: {
          "Accept": "application/json",
          "X-CSRF-Token": csrfToken
        }
      })

      const data = await response.json()

      if (!response.ok || !data.success) {
        this.showStatus(statusTarget, data.error || "Retry failed", "red")
        this.showRefreshButton(type)
        return
      }

      this.pollActionStatus(actionId, type)
    } catch {
      this.showStatus(statusTarget, "Retry failed", "red")
      this.showRefreshButton(type)
    }
  }

  showStatus(targetName, message, color) {
    const colorClasses = {
      amber: "text-amber-600 dark:text-amber-400",
      green: "text-green-600 dark:text-green-400",
      red: "text-red-600 dark:text-red-400"
    }
    const target = this.statusTargetElement(targetName)
    if (!target) return
    target.textContent = message
    target.className = `text-xs ${colorClasses[color] || ""}`
  }

  clearStatusAfter(targetName, ms) {
    setTimeout(() => {
      const target = this.statusTargetElement(targetName)
      if (target) target.textContent = ""
    }, ms)
  }

  statusTargetElement(targetName) {
    if (targetName === "likeStatus") return this.hasLikeStatusTarget ? this.likeStatusTarget : null
    if (targetName === "followStatus") return this.hasFollowStatusTarget ? this.followStatusTarget : null
    if (targetName === "muteStatus") return this.hasMuteStatusTarget ? this.muteStatusTarget : null
    return null
  }

  showRefreshButton(type, visible = true) {
    let target
    if (type === "like") target = this.hasLikeRefreshButtonTarget ? this.likeRefreshButtonTarget : null
    else if (type === "follow") target = this.hasFollowRefreshButtonTarget ? this.followRefreshButtonTarget : null
    else if (type === "mute") target = this.hasMuteRefreshButtonTarget ? this.muteRefreshButtonTarget : null
    if (!target) return
    target.classList.toggle("hidden", !visible)
    target.classList.toggle("inline-flex", visible)
  }

  hideRefreshButton(type) {
    this.showRefreshButton(type, false)
  }

  disconnect() {
    if (this._pollIntervals) {
      Object.values(this._pollIntervals).forEach(id => clearInterval(id))
    }
  }
}
