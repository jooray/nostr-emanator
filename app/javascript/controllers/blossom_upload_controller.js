import { Controller } from "@hotwired/stimulus"

// Uploads dropped/selected/pasted files to the account's Blossom server (via the
// Rails proxy) and inserts the returned URL at the cursor in the post textarea.
export default class extends Controller {
  static targets = ["textarea", "input", "status"]
  static values = { uploadUrl: String }

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

    const csrfToken = document.querySelector('meta[name="csrf-token"]')?.content

    for (const file of files) {
      this.setStatus(`Uploading ${file.name}…`, false)
      try {
        const formData = new FormData()
        formData.append("file", file)

        const response = await fetch(this.uploadUrlValue, {
          method: "POST",
          headers: { "X-CSRF-Token": csrfToken, "Accept": "application/json" },
          body: formData // no Content-Type: browser sets the multipart boundary
        })

        const data = await response.json().catch(() => ({}))
        if (!response.ok) throw new Error(data.error || `Upload failed (${response.status})`)

        this.insertAtCursor(data.url)
        this.setStatus("", false)
      } catch (error) {
        this.setStatus(error.message || "Upload failed", true)
        return
      }
    }
  }

  insertAtCursor(url) {
    const ta = this.textareaTarget
    const start = ta.selectionStart ?? ta.value.length
    const end = ta.selectionEnd ?? ta.value.length
    const before = ta.value.slice(0, start)
    const after = ta.value.slice(end)

    // Add a separating space only when the neighbour isn't already whitespace
    // (and isn't a string boundary) — avoids doubling up whitespace.
    const lead = before.length > 0 && !/\s$/.test(before) ? " " : ""
    const trail = after.length > 0 && !/^\s/.test(after) ? " " : ""
    const insertion = lead + url + trail

    ta.value = before + insertion + after
    const caret = start + insertion.length
    ta.setSelectionRange(caret, caret)
    ta.focus()
    // Refresh media-preview thumbnails + any content-builder listeners.
    ta.dispatchEvent(new Event("input", { bubbles: true }))
  }

  setStatus(message, isError) {
    if (!this.hasStatusTarget) return
    this.statusTarget.textContent = message
    this.statusTarget.classList.toggle("text-red-500", !!isError)
    this.statusTarget.classList.toggle("text-gray-400", !isError)
  }
}
