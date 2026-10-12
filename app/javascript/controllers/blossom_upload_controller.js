import { Controller } from "@hotwired/stimulus"
import { t } from "../lib/i18n"
import { shouldShrink, shrinkImage, humanSize } from "../lib/media_compress"
import { offerVideoChoice, shouldShrinkVideo, useReencoded } from "../lib/video_rules"

// Uploads dropped/selected/pasted files to the account's Blossom server and
// inserts the returned URL at the cursor in the post textarea.
//
// The POST only *stages* the file: the server answers 202 with an upload id and
// does the NIP-46 signing + PUT in a background job (C6), so we poll for status
// and can show step-level progress ("Approve the upload in your signer app…").
// While anything is in flight the form's submit buttons are disabled so the
// draft can't be saved without the media URL.
//
// Each file gets a row under the textarea (the `list` target): its name, what
// is happening now, a progress bar (with a percentage where one is known:
// re-encoding and sending to Emanator; moving otherwise), and a note such as
// the size saved. Finished rows fade out; failed ones stay until dismissed.
export default class extends Controller {
  static targets = ["textarea", "input", "list", "videoChoice", "videoChoiceNames"]
  // media: the user's MediaPreferences (shared with the Android app).
  // videoCompressUrl: the separately bundled video encoder, loaded on demand.
  // maxBytes: the server's upload limit; a video within it may go up unconverted.
  static values = { uploadUrl: String, media: Object, videoCompressUrl: String, maxBytes: Number }

  POLL_INTERVAL = 1000
  POLL_TIMEOUT = 6 * 60 * 1000

  connect() {
    this.uploads = new Map() // key -> { name, message, percent, note, state: "active" | "done" | "failed" }
    this.nextKey = 0
    // A file dropped anywhere outside the textarea (still inside the window)
    // would otherwise navigate the browser to it and lose the draft — block
    // that at the window level for as long as the composer is on screen.
    this.preventWindowDrop = (event) => event.preventDefault()
    window.addEventListener("dragover", this.preventWindowDrop)
    window.addEventListener("drop", this.preventWindowDrop)
    // Belt and braces: warn if the page is closed mid-upload.
    this.beforeUnload = (event) => {
      if (this.activeCount() === 0) return
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
    if (this.activeCount() === 0) {
      const ta = this.textareaTarget
      this.insertionPoint = ta.selectionStart ?? ta.value.length
    }

    // A video that could go up as it is asks how (once for the whole batch).
    // Cancelling drops those videos; everything else still uploads.
    const askable = files.filter((file) => this.canReencodeVideo() && offerVideoChoice(file, this.mediaValue, this.maxBytesValue))
    const videoMode = askable.length ? await this.askVideoMode(askable) : null
    const queued = videoMode ? files : files.filter((file) => !askable.includes(file))
    if (queued.length === 0) return

    // H10: one file failing must not drop the rest — each reports on its own row.
    await Promise.all(queued.map((file) => this.uploadOne(file, askable.includes(file) ? videoMode : "reencode")))
  }

  async uploadOne(file, videoMode) {
    const key = this.nextKey++
    this.track(key, { name: file.name, message: t("js.blossom_upload.preparing"), percent: null })

    try {
      file = await this.shrink(key, file, videoMode)
      const data = await this.send(key, file)
      this.track(key, { message: t("js.blossom_upload.uploading"), percent: null })
      const url = await this.pollUntilDone(key, data.status_url || `/blossom_uploads/${data.id}`)
      this.insertAtCursor(url)
      this.track(key, { message: t("js.blossom_upload.attached"), percent: 100, state: "done" })
      setTimeout(() => this.untrack(key), 4000)
    } catch (error) {
      this.track(key, { message: error.message || t("js.blossom_upload.failed"), percent: null, state: "failed" })
    }
  }

  // The POST to Emanator, as XHR rather than fetch: only XHR reports upload
  // progress, and a large video takes a while to leave the browser.
  send(key, file) {
    const formData = new FormData()
    formData.append("file", file)

    return new Promise((resolve, reject) => {
      const xhr = new XMLHttpRequest()
      xhr.open("POST", this.uploadUrlValue)
      xhr.setRequestHeader("X-CSRF-Token", this.csrfToken())
      xhr.setRequestHeader("Accept", "application/json")
      xhr.upload.onprogress = (event) => {
        if (!event.lengthComputable) return
        const percent = Math.min(99, Math.round((event.loaded / event.total) * 100))
        this.track(key, { message: t("js.blossom_upload.sending", { percent }), percent })
      }
      xhr.onload = () => {
        let data = {}
        try { data = JSON.parse(xhr.responseText) } catch { /* not JSON */ }
        if (xhr.status >= 200 && xhr.status < 300) resolve(data)
        else reject(new Error(data.error || t("js.blossom_upload.failed_status", { status: xhr.status })))
      }
      xhr.onerror = () => reject(new Error(t("js.blossom_upload.failed")))
      this.track(key, { message: t("js.blossom_upload.sending", { percent: 0 }), percent: 0 })
      xhr.send(formData) // no Content-Type: the browser sets the multipart boundary
    })
  }

  // Photos are shrunk (and stripped of metadata) before they leave the
  // browser — see lib/media_compress.js. A failure here never blocks the
  // upload: the original goes up instead.
  async shrink(key, file, videoMode) {
    if (shouldShrinkVideo(file, this.mediaValue)) return this.shrinkVideo(key, file, videoMode)
    if (!shouldShrink(file, this.mediaValue)) return file

    this.track(key, { message: t("js.media_compress.compressing"), percent: null })
    try {
      const result = await shrinkImage(file, this.mediaValue)
      if (result.shrunk) {
        this.track(key, {
          name: result.file.name,
          note: t("js.media_compress.saved", { from: humanSize(result.original), to: humanSize(result.file.size) })
        })
      }
      return result.file
    } catch {
      return file
    }
  }

  // Videos too, where the browser has WebCodecs; elsewhere, and on any error,
  // the original goes up. `videoMode` is the answer to askVideoMode.
  async shrinkVideo(key, file, videoMode) {
    if (!this.hasVideoCompressUrlValue || videoMode === "original") return file

    this.track(key, { message: t("js.media_compress.video_compressing", { percent: 0 }), percent: 0 })
    try {
      const { shrinkVideo } = await import(this.videoCompressUrlValue)
      const result = await shrinkVideo(file, this.mediaValue, (progress) => {
        const percent = Math.min(99, Math.round(progress * 100))
        this.track(key, { message: t("js.media_compress.video_compressing", { percent }), percent })
      })
      if (result.shrunk && !useReencoded(videoMode, file.size, result.file.size)) {
        this.track(key, {
          note: t("js.media_compress.kept_original", { original: humanSize(file.size), reencoded: humanSize(result.file.size) })
        })
        return file
      }
      if (result.shrunk) {
        this.track(key, {
          name: result.file.name,
          note: t("js.media_compress.saved", { from: humanSize(result.original), to: humanSize(result.file.size) })
        })
      }
      return result.file
    } catch {
      return file
    }
  }

  // Only worth asking where this browser can re-encode at all.
  canReencodeVideo() {
    return this.hasVideoCompressUrlValue && this.hasVideoChoiceTarget &&
      typeof VideoEncoder !== "undefined" && typeof VideoDecoder !== "undefined"
  }

  // Resolves to "original" | "reencode" | "smaller", or null when dismissed.
  askVideoMode(files) {
    const dialog = this.videoChoiceTarget
    this.videoChoiceNamesTarget.textContent = files.map((f) => `${f.name} (${humanSize(f.size)})`).join(", ")
    return new Promise((resolve) => {
      dialog.addEventListener("close", () => resolve(dialog.returnValue || null), { once: true })
      dialog.returnValue = ""
      dialog.showModal()
    })
  }

  chooseVideoMode({ params: { mode } }) {
    this.videoChoiceTarget.close(mode || "")
  }

  async pollUntilDone(key, statusUrl) {
    const deadline = Date.now() + this.POLL_TIMEOUT

    while (Date.now() < deadline) {
      await this.sleep(this.POLL_INTERVAL)

      const response = await fetch(statusUrl, { headers: { "Accept": "application/json" } })
      if (!response.ok) throw new Error(t("js.blossom_upload.status_unreadable", { status: response.status }))
      const data = await response.json()

      if (data.status === "completed") return data.url
      if (data.status === "failed") throw new Error(data.error || t("js.blossom_upload.failed"))

      this.track(key, { message: data.step || t("js.blossom_upload.uploading"), percent: null })
    }

    throw new Error(t("js.blossom_upload.timed_out"))
  }

  sleep(ms) {
    return new Promise((resolve) => setTimeout(resolve, ms))
  }

  csrfToken() {
    return document.querySelector('meta[name="csrf-token"]')?.content
  }

  // --- status rows + submit locking -----------------------------------------

  // Merges `changes` into the file's row (created on first call) and redraws.
  track(key, changes) {
    const row = { state: "active", note: null, ...this.uploads.get(key), ...changes }
    this.uploads.set(key, row)
    this.render()
    this.setSubmitDisabled(this.activeCount() > 0)
  }

  untrack(key) {
    this.uploads.delete(key)
    this.render()
    this.setSubmitDisabled(this.activeCount() > 0)
  }

  dismiss(event) {
    this.untrack(Number(event.params.key))
  }

  activeCount() {
    let n = 0
    this.uploads.forEach((row) => { if (row.state === "active") n++ })
    return n
  }

  // Built with DOM calls, not innerHTML: file names and server errors are text.
  render() {
    if (!this.hasListTarget) return
    const list = this.listTarget
    list.replaceChildren()
    list.hidden = this.uploads.size === 0

    this.uploads.forEach((row, key) => {
      const failed = row.state === "failed"
      const item = el("li", "py-2")

      const head = el("div", "flex items-baseline gap-3 text-xs")
      head.append(
        el("span", "min-w-0 truncate font-medium text-gray-700 dark:text-gray-200", row.name),
        el("span", `ml-auto shrink-0 text-right ${failed ? "text-red-600 dark:text-red-400" : "text-gray-500 dark:text-gray-400"}`, row.message)
      )
      if (failed) {
        const close = el("button", "shrink-0 text-gray-400 hover:text-gray-700 dark:hover:text-gray-200 cursor-pointer", "×")
        close.type = "button"
        close.setAttribute("aria-label", t("js.blossom_upload.dismiss"))
        close.dataset.action = "blossom-upload#dismiss"
        close.dataset.blossomUploadKeyParam = key
        head.append(close)
      }
      item.append(head)

      if (!failed) {
        const track = el("div", "mt-1.5 h-1 overflow-hidden rounded-full bg-gray-200 dark:bg-gray-700")
        const bar = el("div", "h-full rounded-full bg-amber-500 transition-[width] duration-300")
        if (row.percent == null) bar.classList.add("upload-bar-indeterminate")
        else bar.style.width = `${row.percent}%`
        track.setAttribute("role", "progressbar")
        if (row.percent != null) track.setAttribute("aria-valuenow", row.percent)
        track.append(bar)
        item.append(track)
      }
      if (row.note) item.append(el("p", "mt-1 text-xs text-gray-400 dark:text-gray-500", row.note))
      list.append(item)
    })
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
        const label = t("js.blossom_upload.waiting")
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

function el(tag, className, text) {
  const node = document.createElement(tag)
  node.className = className
  if (text != null) node.textContent = text
  return node
}
