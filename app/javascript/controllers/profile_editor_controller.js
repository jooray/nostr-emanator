import { Controller } from "@hotwired/stimulus"

// Drives the Nostr profile editor: the live preview, Blossom image uploads, and
// the publish-then-poll cycle.
//
// Both uploading and publishing block on the user approving in their signer app,
// so neither can happen inside a request — each enqueues a job and this polls a
// status row.
export default class extends Controller {
  static targets = [
    "displayName", "name", "about", "website", "nip05", "lud16",
    "picture", "banner", "pictureStatus", "bannerStatus",
    "previewBanner", "previewAvatar", "previewAvatarFallback",
    "previewDisplayName", "previewHandle", "previewNip05",
    "previewAbout", "previewWebsite", "previewLud16",
    "previewWebsiteRow", "previewLud16Row",
    "publishButton", "publishLabel", "status", "errorBox", "errorText"
  ]
  static values = { uploadUrl: String, publishUrl: String }

  connect() {
    this.pollTimers = new Set()
    this.sync()
  }

  disconnect() {
    this.pollTimers.forEach((t) => clearTimeout(t))
    this.pollTimers.clear()
    if (this.filePicker) this.filePicker.remove()
  }

  // --- Live preview ---------------------------------------------------------

  sync() {
    const displayName = this.valueOf_("displayName")
    const handle = this.valueOf_("name")

    // Clients fall back through display_name -> name -> something generic, so
    // the preview has to do the same or it lies about an empty display name.
    this.previewDisplayNameTarget.textContent = displayName || handle || "Unnamed"
    this.previewHandleTarget.textContent = handle ? `@${handle}` : ""
    this.previewAboutTarget.textContent = this.valueOf_("about")
    this.previewNip05Target.textContent = this.valueOf_("nip05")

    const website = this.valueOf_("website")
    this.previewWebsiteTarget.textContent = website
    this.previewWebsiteRowTarget.classList.toggle("hidden", !website)

    const lud16 = this.valueOf_("lud16")
    this.previewLud16Target.textContent = lud16
    this.previewLud16RowTarget.classList.toggle("hidden", !lud16)

    this.setImage(this.previewBannerTarget, this.valueOf_("banner"))
    this.setImage(this.previewAvatarTarget, this.valueOf_("picture"))

    // Initial of whatever name will actually be shown, so an avatarless profile
    // previews as the client would render it rather than as a blank disc.
    const seed = displayName || handle
    this.previewAvatarFallbackTarget.textContent = seed ? seed.trim().charAt(0).toUpperCase() : "?"
    this.previewAvatarFallbackTarget.classList.toggle("hidden", !!this.valueOf_("picture"))
  }

  valueOf_(name) {
    const target = `${name}Target`
    return this[`has${name.charAt(0).toUpperCase()}${name.slice(1)}Target`] ? this[target].value.trim() : ""
  }

  setImage(img, url) {
    if (!url) {
      img.classList.add("hidden")
      img.removeAttribute("src")
      return
    }
    if (img.getAttribute("src") !== url) img.setAttribute("src", url)
    img.classList.remove("hidden")
  }

  // A URL that 404s or is not an image would otherwise leave a broken-image
  // glyph that looks like our bug rather than a bad link.
  imageFailed(event) {
    event.target.classList.add("hidden")
    if (event.target === this.previewAvatarTarget) {
      this.previewAvatarFallbackTarget.classList.remove("hidden")
    }
  }

  // --- Blossom upload -------------------------------------------------------

  pickImage(event) {
    const field = event.currentTarget.dataset.field
    if (!this.filePicker) {
      this.filePicker = document.createElement("input")
      this.filePicker.type = "file"
      this.filePicker.accept = "image/*"
      this.filePicker.className = "hidden"
      document.body.appendChild(this.filePicker)
    }
    this.filePicker.value = ""
    this.filePicker.onchange = () => {
      const file = this.filePicker.files?.[0]
      if (file) this.upload(field, file)
    }
    this.filePicker.click()
  }

  async upload(field, file) {
    const statusTarget = this[`${field}StatusTarget`]
    statusTarget.textContent = "Uploading…"

    const body = new FormData()
    body.append("file", file)

    try {
      const response = await fetch(this.uploadUrlValue, {
        method: "POST",
        headers: { "X-CSRF-Token": this.csrfToken() },
        body
      })
      const data = await response.json()

      if (data.status === "failed" || data.error) {
        statusTarget.textContent = data.error || "Upload failed."
        return
      }
      this.pollUpload(field, data.status_url)
    } catch (error) {
      console.error("Upload error:", error)
      statusTarget.textContent = "Could not reach the server."
    }
  }

  pollUpload(field, statusUrl) {
    const statusTarget = this[`${field}StatusTarget`]
    const tick = async () => {
      try {
        const data = await (await fetch(statusUrl)).json()

        if (data.status === "completed" && data.url) {
          this[`${field}Target`].value = data.url
          statusTarget.textContent = "Uploaded."
          this.sync()
          return
        }
        if (data.status === "failed") {
          statusTarget.textContent = data.error || "Upload failed."
          return
        }
        statusTarget.textContent = data.step || "Working…"
        this.later(tick, 1000)
      } catch (error) {
        console.error("Upload poll error:", error)
        statusTarget.textContent = "Lost contact with the server."
      }
    }
    this.later(tick, 600)
  }

  // --- Publish --------------------------------------------------------------

  async publish(event) {
    event.preventDefault()
    this.hideError()

    this.publishButtonTarget.disabled = true
    this.publishLabelTarget.textContent = "Publishing…"
    this.statusTarget.textContent = "Preparing…"

    try {
      const response = await fetch(this.publishUrlValue, {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "X-CSRF-Token": this.csrfToken()
        },
        body: JSON.stringify({ profile: this.collect() })
      })
      const data = await response.json()

      if (!data.ok) {
        this.failPublish(data.error || "Could not start publishing.")
        return
      }
      this.pollPublish(data.poll_url)
    } catch (error) {
      console.error("Publish error:", error)
      this.failPublish("Could not reach the server. Check your connection and try again.")
    }
  }

  collect() {
    const fields = ["displayName", "name", "about", "picture", "banner", "website", "nip05", "lud16"]
    const out = {}
    fields.forEach((f) => {
      // display_name is the wire name; displayName is only the Stimulus target.
      const key = f === "displayName" ? "display_name" : f
      out[key] = this.valueOf_(f)
    })
    return out
  }

  pollPublish(pollUrl) {
    const tick = async () => {
      try {
        const data = await (await fetch(pollUrl)).json()

        if (data.status === "completed") {
          this.statusTarget.textContent = "Published."
          this.publishButtonTarget.disabled = false
          this.publishLabelTarget.textContent = "Publish profile"
          return
        }
        if (data.status === "failed") {
          this.failPublish(data.error || "Publishing failed.")
          return
        }
        this.statusTarget.textContent = data.step || "Working…"
        this.later(tick, 1000)
      } catch (error) {
        console.error("Publish poll error:", error)
        this.failPublish("Lost contact with the server while publishing.")
      }
    }
    this.later(tick, 600)
  }

  failPublish(message) {
    this.statusTarget.textContent = ""
    this.publishButtonTarget.disabled = false
    this.publishLabelTarget.textContent = "Publish profile"
    this.showError(message)
  }

  // --- helpers --------------------------------------------------------------

  later(fn, ms) {
    const t = setTimeout(() => {
      this.pollTimers.delete(t)
      fn()
    }, ms)
    this.pollTimers.add(t)
  }

  csrfToken() {
    return document.querySelector("meta[name='csrf-token']")?.content
  }

  showError(message) {
    this.errorTextTarget.textContent = message
    this.errorBoxTarget.classList.remove("hidden")
  }

  hideError() {
    this.errorBoxTarget.classList.add("hidden")
  }
}
