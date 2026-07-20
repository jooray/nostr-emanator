import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["refineInput", "form", "editorContainer", "textarea", "refineSection"]
  static values = { streamUrl: String, refineUrl: String, autoGenerate: Boolean }

  connect() {
    this.streamAbortController = null

    if (this.autoGenerateValue) {
      setTimeout(() => this.startStreaming(), 100)
    }
  }

  disconnect() {
    this.streamAbortController?.abort()
    this.streamAbortController = null
  }

  insertContentIntoTextarea(content) {
    if (!this.hasTextareaTarget) return

    // Generate/Refine used to overwrite whatever the user had already typed
    // with no way back. Snapshot it so an accidental overwrite is recoverable.
    const previousContent = this.textareaTarget.value
    const hadDifferentContent = previousContent.trim().length > 0 && previousContent !== content

    this.textareaTarget.value = content
    this.textareaTarget.dispatchEvent(new Event("input", { bubbles: true }))
    this.textareaTarget.scrollIntoView({ behavior: "smooth", block: "center" })

    if (hadDifferentContent) {
      this.showUndoBanner(previousContent)
    } else {
      this.removeUndoBanner()
    }
  }

  showUndoBanner(previousContent) {
    this.removeUndoBanner()

    const banner = document.createElement("div")
    banner.dataset.contentBuilderUndoBanner = "true"
    banner.className = "mt-2 flex items-center gap-2 text-xs text-amber-700 dark:text-amber-300"

    const label = document.createElement("span")
    label.textContent = "Your previous text was replaced."
    banner.appendChild(label)

    const button = document.createElement("button")
    button.type = "button"
    button.className = "font-medium underline"
    button.textContent = "Undo"
    button.addEventListener("click", () => {
      this.textareaTarget.value = previousContent
      this.textareaTarget.dispatchEvent(new Event("input", { bubbles: true }))
      banner.remove()
    })
    banner.appendChild(button)

    this.textareaTarget.insertAdjacentElement("afterend", banner)
  }

  removeUndoBanner() {
    if (!this.hasTextareaTarget) return
    this.textareaTarget.parentElement?.querySelector("[data-content-builder-undo-banner]")?.remove()
  }

  showRefineSection() {
    if (this.hasRefineSectionTarget) {
      this.refineSectionTarget.classList.remove("hidden")
    }
  }

  startStreaming(event = null) {
    if (event) event.preventDefault()

    const streamUrl = this.streamUrlValue
    if (!streamUrl) return

    // Get the prompt from the input field
    const promptInput = this.element.querySelector("input[name='prompt']")
    const prompt = promptInput ? promptInput.value.trim() : ""
    if (!prompt) {
      alert("Please enter a prompt for the AI")
      return
    }

    const container = this.hasEditorContainerTarget ? this.editorContainerTarget : document.getElementById("editor-container")
    if (!container) return

    container.innerHTML = `
      <div class="space-y-4">
        <div class="flex items-center gap-3 p-4 bg-amber-50 dark:bg-amber-900/20 border border-amber-200 dark:border-amber-800 rounded-lg">
          <div class="animate-spin" id="streaming-spinner">
            <svg class="w-5 h-5 text-amber-600 dark:text-amber-400" fill="none" stroke="currentColor" viewBox="0 0 24 24">
              <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M4 4v5h.582m15.356 2A8.001 8.001 0 004.582 9m0 0H9m11 11v-5h-.581m0 0a8.003 8.003 0 01-15.357-2m15.357 2H15"/>
            </svg>
          </div>
          <div>
            <p class="text-sm font-medium text-amber-900 dark:text-amber-200" id="streaming-status">Connecting to AI...</p>
            <p class="text-xs text-amber-700 dark:text-amber-300">Content will appear below as it's generated.</p>
          </div>
        </div>
        <div class="p-4 bg-gray-50 dark:bg-gray-900 rounded-lg border border-gray-200 dark:border-gray-700 min-h-[400px]">
          <pre id="streaming-content" class="whitespace-pre-wrap text-sm text-gray-900 dark:text-gray-100 font-mono"></pre>
        </div>
      </div>
    `

    const contentEl = document.getElementById("streaming-content")
    const statusEl = document.getElementById("streaming-status")
    const spinnerEl = document.getElementById("streaming-spinner")

    const markComplete = () => {
      spinnerEl.classList.remove("animate-spin")
      spinnerEl.innerHTML = `
        <svg class="w-5 h-5 text-green-600 dark:text-green-400" fill="none" stroke="currentColor" viewBox="0 0 24 24">
          <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M5 13l4 4L19 7"/>
        </svg>
      `
    }

    this.streamSSE(streamUrl, { prompt }, {
      onPhase: (data) => {
        if (data.phase === "generating") {
          statusEl.textContent = "Generating content..."
        } else if (data.phase === "humanizing") {
          contentEl.textContent = ""
          statusEl.textContent = "Humanizing content..."
        }
      },
      onChunk: (chunk) => {
        contentEl.textContent += chunk
      },
      onComplete: (data) => {
        statusEl.textContent = "Generation complete!"
        markComplete()

        if (data && typeof data === "object" && data.content) {
          this.insertContentIntoTextarea(data.content)
        } else {
          // Fallback: use the streamed content from the preview
          const finalContent = contentEl.textContent
          if (finalContent) {
            this.insertContentIntoTextarea(finalContent)
          }
        }

        this.showRefineSection()
      },
      onError: (data) => {
        const errorMsg = (data && data.message) || "Connection lost. Please try again."
        statusEl.textContent = "Error: " + errorMsg
        spinnerEl.classList.remove("animate-spin")
      }
    })
  }

  startRefineStreaming(event = null) {
    if (event) event.preventDefault()

    const refineUrl = this.refineUrlValue
    if (!refineUrl) return

    const prompt = this.hasRefineInputTarget ? this.refineInputTarget.value.trim() : ""
    if (!prompt) {
      alert("Please enter instructions for the AI")
      return
    }

    // Read current content from the textarea dynamically
    const currentContent = this.hasTextareaTarget ? this.textareaTarget.value.trim() : ""
    if (!currentContent) {
      alert("No content to refine. Please generate or write some content first.")
      return
    }

    const container = this.hasEditorContainerTarget ? this.editorContainerTarget : document.getElementById("editor-container")
    if (!container) return

    container.innerHTML = `
      <div class="space-y-4">
        <div class="flex items-center gap-3 p-4 bg-amber-50 dark:bg-amber-900/20 border border-amber-200 dark:border-amber-800 rounded-lg">
          <div class="animate-spin" id="streaming-spinner">
            <svg class="w-5 h-5 text-amber-600 dark:text-amber-400" fill="none" stroke="currentColor" viewBox="0 0 24 24">
              <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M4 4v5h.582m15.356 2A8.001 8.001 0 004.582 9m0 0H9m11 11v-5h-.581m0 0a8.003 8.003 0 01-15.357-2m15.357 2H15"/>
            </svg>
          </div>
          <div>
            <p class="text-sm font-medium text-amber-900 dark:text-amber-200" id="streaming-status">Applying AI edits...</p>
            <p class="text-xs text-amber-700 dark:text-amber-300">Instruction: ${this.escapeHtml(prompt)}</p>
          </div>
        </div>
        <div class="p-4 bg-gray-50 dark:bg-gray-900 rounded-lg border border-gray-200 dark:border-gray-700 min-h-[400px]">
          <pre id="streaming-content" class="whitespace-pre-wrap text-sm text-gray-900 dark:text-gray-100 font-mono"></pre>
        </div>
      </div>
    `

    const contentEl = document.getElementById("streaming-content")
    const statusEl = document.getElementById("streaming-status")
    const spinnerEl = document.getElementById("streaming-spinner")

    if (this.hasRefineInputTarget) this.refineInputTarget.value = ""

    const markComplete = () => {
      spinnerEl.classList.remove("animate-spin")
      spinnerEl.innerHTML = `
        <svg class="w-5 h-5 text-green-600 dark:text-green-400" fill="none" stroke="currentColor" viewBox="0 0 24 24">
          <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M5 13l4 4L19 7"/>
        </svg>
      `
    }

    this.streamSSE(refineUrl, { user_prompt: prompt, current_content: currentContent }, {
      onPhase: (data) => {
        if (data.phase === "refining") {
          statusEl.textContent = "Refining content..."
        } else if (data.phase === "humanizing") {
          contentEl.textContent = ""
          statusEl.textContent = "Humanizing content..."
        }
      },
      onChunk: (chunk) => {
        contentEl.textContent += chunk
      },
      onComplete: (data) => {
        statusEl.textContent = "Refinement complete!"
        markComplete()

        if (data && typeof data === "object" && data.content) {
          this.insertContentIntoTextarea(data.content)
        } else {
          const finalContent = contentEl.textContent
          if (finalContent) {
            this.insertContentIntoTextarea(finalContent)
          }
        }
      },
      onError: (data) => {
        const errorMsg = (data && data.message) || "Connection lost. Please try again."
        statusEl.textContent = "Error: " + errorMsg
        spinnerEl.classList.remove("animate-spin")
      }
    })
  }

  // H5: generate_stream/refine_stream are POST endpoints (rate-limited, and no
  // longer triggerable by a bare top-level GET navigation), so they can't be
  // consumed with EventSource, which only ever issues GET. This POSTs with
  // fetch() and reads the response body as a stream, parsing the same
  // `event: <name>\ndata: <payload>\n\n` frames the server already emits —
  // the phase/chunk/complete/error handling is unchanged from the EventSource
  // version, just invoked via callbacks instead of addEventListener.
  async streamSSE(url, params, { onPhase, onChunk, onComplete, onError }) {
    this.streamAbortController?.abort()
    const controller = new AbortController()
    this.streamAbortController = controller

    let response
    try {
      response = await fetch(url, {
        method: "POST",
        headers: {
          "Content-Type": "application/x-www-form-urlencoded",
          "Accept": "text/event-stream",
          "X-CSRF-Token": document.querySelector("meta[name='csrf-token']")?.content
        },
        body: new URLSearchParams(params).toString(),
        signal: controller.signal
      })
    } catch (error) {
      if (error.name !== "AbortError") onError?.({ message: "Connection lost. Please try again." })
      return
    }

    // A non-2xx here means the server never got as far as opening the SSE
    // stream (e.g. a 404/500 before ai_assist_controller's action body runs)
    // — there are no `event:`/`data:` frames to parse, just show the status.
    if (!response.ok || !response.body) {
      onError?.({ message: `Request failed (${response.status})` })
      return
    }

    const reader = response.body.getReader()
    const decoder = new TextDecoder()
    let buffer = ""

    try {
      while (true) {
        const { done, value } = await reader.read()
        if (done) break

        buffer += decoder.decode(value, { stream: true })

        let boundary
        while ((boundary = buffer.indexOf("\n\n")) !== -1) {
          const rawEvent = buffer.slice(0, boundary)
          buffer = buffer.slice(boundary + 2)
          if (rawEvent.trim()) this.dispatchSSEFrame(rawEvent, { onPhase, onChunk, onComplete, onError })
        }
      }
    } catch (error) {
      if (error.name !== "AbortError") onError?.({ message: "Connection lost. Please try again." })
    } finally {
      if (this.streamAbortController === controller) this.streamAbortController = null
    }
  }

  dispatchSSEFrame(rawEvent, { onPhase, onChunk, onComplete, onError }) {
    let eventName = "message"
    const dataLines = []

    rawEvent.split("\n").forEach((line) => {
      if (line.startsWith("event:")) {
        eventName = line.slice(6).trim()
      } else if (line.startsWith("data:")) {
        dataLines.push(line.slice(5).replace(/^ /, ""))
      }
    })

    const raw = dataLines.join("\n")
    let data
    try {
      data = JSON.parse(raw)
    } catch (e) {
      data = raw
    }

    switch (eventName) {
      case "phase":
        onPhase?.(data)
        break
      case "chunk":
        onChunk?.(data)
        break
      case "complete":
        onComplete?.(data)
        break
      case "error":
        onError?.(data)
        break
    }
  }

  escapeHtml(text) {
    const div = document.createElement("div")
    div.textContent = text
    return div.innerHTML
  }
}
