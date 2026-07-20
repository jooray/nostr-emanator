import { Controller } from "@hotwired/stimulus"

// Uploads dropped/selected/pasted files to the account's Blossom server and
// inserts the returned URL at the cursor in the post textarea.
//
// The POST only *stages* the file: the server answers 202 with an upload id and
// does the NIP-46 signing + PUT in a background job (C6), so we poll for status
// and can show step-level progress ("Approve the upload in your signer app…").
// While anything is in flight the form's submit buttons are disabled so the
// draft can't be saved without the media URL.
export default class extends Controller {
  static targets = ["textarea", "input", "status"]
  static values = { uploadUrl: String }

  POLL_INTERVAL = 1000
  POLL_TIMEOUT = 6 * 60 * 1000

  connect() {
    this.uploads = new Map() // key -> { name, message, error }
    this.nextKey = 0
    // A file dropped anywhere outside the textarea (still inside the window)
    // would otherwise navigate the browser to it and lose the draft — block
    // that at the window level for as long as the composer is on screen.
    this.preventWindowDrop = (event) => event.preventDefault()
    window.addEventListener("dragover", this.preventWindowDrop)
    window.addEventListener("drop", this.preventWindowDrop)
    // Belt and braces: warn if the page is closed mid-upload.
    this.beforeUnload = (event) => {
      if (this.uploads.size === 0) return
      event.preventDefault()
      event.returnValue = ""
    }
    window.addEventListener("beforeunload", this.beforeUnload)
  }

  disconnect() {
    window.removeEventListener("dragover", this.preventWindowDrop)
    window.removeEventListener("drop", this.preventWindowDrop)
    window.removeEventListener("beforeunload", this.beforeUnload)
    this.setSubmitDisabled(false)
  }

  // --- triggers -------------------------------------------------------------

  openPicker() {
    this.inputTarget.click()
  }

  picked(event) {
    this.upload(event.target.files)
    event.target.value = "" // allow re-selecting the same file
  }

  dragover(event) {
    event.preventDefault()
    this.textareaTarget.classList.add("ring-2", "ring-amber-500")
  }

  dragleave(event) {
    event.preventDefault()
    this.textareaTarget.classList.remove("ring-2", "ring-amber-500")
  }

  drop(event) {
    event.preventDefault()
    this.textareaTarget.classList.remove("ring-2", "ring-amber-500")
    if (event.dataTransfer?.files?.length) this.upload(event.dataTransfer.files)
  }

  paste(event) {
    const files = Array.from(event.clipboardData?.files || [])
    if (files.length) {
      event.preventDefault()
      this.upload(files)
    }
  }

  // --- upload ---------------------------------------------------------------

  async upload(fileList) {
    const files = Array.from(fileList || [])
    if (files.length === 0) return

    // Remember where the caret was when the upload started; every inserted URL
    // goes there and moves the point forward, so results land in order even
    // when the user keeps typing (or a later file finishes first).
    if (this.uploads.size === 0) {
      const ta = this.textareaTarget
      this.insertionPoint = ta.selectionStart ?? ta.value.length
    }

    // H10: one file failing must not drop the rest — run them all and report
    // per-file errors.
    const results = await Promise.all(files.map((file) => this.uploadOne(file)))
    const errors = results.filter((r) => r && r.error)

    if (this.uploads.size === 0) {
      if (errors.length > 0) {
        this.setStatus(errors.map((e) => `${e.name}: ${e.error}`).join(" · "), true)
      } else {
        this.setStatus("", false)
      }
    }
  }

  async uploadOne(file) {
    const key = this.nextKey++
    this.track(key, file.name, "Uploading…")

    try {
      const formData = new FormData()
      formData.append("file", file)

      const response = await fetch(this.uploadUrlValue, {
        method: "POST",
        headers: { "X-CSRF-Token": this.csrfToken(), "Accept": "application/json" },
        body: formData // no Content-Type: browser sets the multipart boundary
      })

      const data = await response.json().catch(() => ({}))
      if (!response.ok) throw new Error(data.error || `Upload failed (${response.status})`)

      const url = await this.pollUntilDone(key, file.name, data.status_url || `/blossom_uploads/${data.id}`)
      this.insertAtCursor(url)
      this.untrack(key)
      return { name: file.name }
    } catch (error) {
      this.untrack(key)
      return { name: file.name, error: error.message || "Upload failed" }
    }
  }

  async pollUntilDone(key, name, statusUrl) {
    const deadline = Date.now() + this.POLL_TIMEOUT

    while (Date.now() < deadline) {
      await this.sleep(this.POLL_INTERVAL)

      const response = await fetch(statusUrl, { headers: { "Accept": "application/json" } })
      if (!response.ok) throw new Error(`Could not read upload status (${response.status})`)
      const data = await response.json()

      if (data.status === "completed") return data.url
      if (data.status === "failed") throw new Error(data.error || "Upload failed")

      this.track(key, name, data.step || "Uploading…")
    }

    throw new Error("Upload timed out")
  }

  sleep(ms) {
    return new Promise((resolve) => setTimeout(resolve, ms))
  }

  csrfToken() {
    return document.querySelector('meta[name="csrf-token"]')?.content
  }

  // --- status + submit locking ----------------------------------------------

  track(key, name, message) {
    this.uploads.set(key, { name, message })
    this.renderStatus()
    this.setSubmitDisabled(true)
  }

  untrack(key) {
    this.uploads.delete(key)
    this.renderStatus()
    if (this.uploads.size === 0) this.setSubmitDisabled(false)
  }

  renderStatus() {
    if (this.uploads.size === 0) return
    const lines = Array.from(this.uploads.values()).map((u) => `${u.name}: ${u.message}`)
    this.setStatus(lines.join(" · "), false)
  }

  setStatus(message, isError) {
    if (!this.hasStatusTarget) return
    this.statusTarget.textContent = message
    this.statusTarget.classList.toggle("text-red-500", !!isError)
    this.statusTarget.classList.toggle("text-gray-400", !isError)
  }

  // C6: submitting during an upload used to navigate away and lose the media URL.
  setSubmitDisabled(disabled) {
    const form = this.element.closest("form")
    if (!form) return

    form.querySelectorAll('input[type="submit"], button[type="submit"]').forEach((el) => {
      el.disabled = disabled
      el.classList.toggle("opacity-50", disabled)
      el.classList.toggle("cursor-not-allowed", disabled)
      if (disabled) {
        if (!el.dataset.blossomOriginalLabel) {
          el.dataset.blossomOriginalLabel = el.tagName === "INPUT" ? el.value : el.textContent
        }
        const label = "Waiting for upload…"
        if (el.tagName === "INPUT") el.value = label
        else el.textContent = label
      } else if (el.dataset.blossomOriginalLabel) {
        if (el.tagName === "INPUT") el.value = el.dataset.blossomOriginalLabel
        else el.textContent = el.dataset.blossomOriginalLabel
        delete el.dataset.blossomOriginalLabel
      }
    })
  }

  insertAtCursor(url) {
    const ta = this.textareaTarget
    // Clamp: the user may have edited (shortened) the text while we waited.
    const saved = this.insertionPoint ?? ta.selectionStart ?? ta.value.length
    const start = Math.min(saved, ta.value.length)
    const end = start
    const before = ta.value.slice(0, start)
    const after = ta.value.slice(end)

    // Add a separating space only when the neighbour isn't already whitespace
    // (and isn't a string boundary) — avoids doubling up whitespace.
    const lead = before.length > 0 && !/\s$/.test(before) ? " " : ""
    const trail = after.length > 0 && !/^\s/.test(after) ? " " : ""
    const insertion = lead + url + trail

    ta.value = before + insertion + after
    const caret = start + insertion.length
    this.insertionPoint = caret
    ta.setSelectionRange(caret, caret)
    ta.focus()
    // Refresh media-preview thumbnails + any content-builder listeners.
    ta.dispatchEvent(new Event("input", { bubbles: true }))
  }
}
