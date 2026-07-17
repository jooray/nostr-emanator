import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["refineInput", "form", "editorContainer", "textarea", "refineSection"]
  static values = { streamUrl: String, refineUrl: String, autoGenerate: Boolean }

  connect() {
    this.eventSource = null

    if (this.autoGenerateValue) {
      setTimeout(() => this.startStreaming(), 100)
    }
  }

  disconnect() {
    if (this.eventSource) {
      this.eventSource.close()
    }
  }

  insertContentIntoTextarea(content) {
    if (!this.hasTextareaTarget) return

    this.textareaTarget.value = content
    this.textareaTarget.dispatchEvent(new Event("input", { bubbles: true }))
    this.textareaTarget.scrollIntoView({ behavior: "smooth", block: "center" })
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

    const url = new URL(streamUrl, window.location.origin)
    url.searchParams.set("prompt", prompt)
    this.eventSource = new EventSource(url.toString())

    this.eventSource.addEventListener("phase", (event) => {
      const data = JSON.parse(event.data)
      if (data.phase === "generating") {
        statusEl.textContent = "Generating content..."
      } else if (data.phase === "humanizing") {
        contentEl.textContent = ""
        statusEl.textContent = "Humanizing content..."
      }
    })

    this.eventSource.addEventListener("chunk", (event) => {
      const chunk = JSON.parse(event.data)
      contentEl.textContent += chunk
    })

    this.eventSource.addEventListener("complete", (event) => {
      this.eventSource.close()
      statusEl.textContent = "Generation complete!"
      spinnerEl.classList.remove("animate-spin")
      spinnerEl.innerHTML = `
        <svg class="w-5 h-5 text-green-600 dark:text-green-400" fill="none" stroke="currentColor" viewBox="0 0 24 24">
          <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M5 13l4 4L19 7"/>
        </svg>
      `

      try {
        const data = JSON.parse(event.data)
        if (data.content) {
          this.insertContentIntoTextarea(data.content)
        }
      } catch (e) {
        // Fallback: use the streamed content from the preview
        const finalContent = contentEl.textContent
        if (finalContent) {
          this.insertContentIntoTextarea(finalContent)
        }
      }

      this.showRefineSection()
    })

    this.eventSource.addEventListener("error", (event) => {
      let errorMsg = "An error occurred"
      try {
        const data = JSON.parse(event.data)
        errorMsg = data.message || errorMsg
      } catch (e) {
        errorMsg = "Connection lost. Please try again."
      }
      this.eventSource.close()
      statusEl.textContent = "Error: " + errorMsg
      spinnerEl.classList.remove("animate-spin")
    })

    this.eventSource.onerror = () => {
      if (this.eventSource.readyState === EventSource.CLOSED) return
      this.eventSource.close()
    }
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

    const url = new URL(refineUrl, window.location.origin)
    url.searchParams.set("user_prompt", prompt)
    url.searchParams.set("current_content", currentContent)

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

    this.eventSource = new EventSource(url.toString())

    this.eventSource.addEventListener("phase", (event) => {
      const data = JSON.parse(event.data)
      if (data.phase === "refining") {
        statusEl.textContent = "Refining content..."
      } else if (data.phase === "humanizing") {
        contentEl.textContent = ""
        statusEl.textContent = "Humanizing content..."
      }
    })

    this.eventSource.addEventListener("chunk", (event) => {
      const chunk = JSON.parse(event.data)
      contentEl.textContent += chunk
    })

    this.eventSource.addEventListener("complete", (event) => {
      this.eventSource.close()
      statusEl.textContent = "Refinement complete!"
      spinnerEl.classList.remove("animate-spin")
      spinnerEl.innerHTML = `
        <svg class="w-5 h-5 text-green-600 dark:text-green-400" fill="none" stroke="currentColor" viewBox="0 0 24 24">
          <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M5 13l4 4L19 7"/>
        </svg>
      `

      try {
        const data = JSON.parse(event.data)
        if (data.content) {
          this.insertContentIntoTextarea(data.content)
        }
      } catch (e) {
        const finalContent = contentEl.textContent
        if (finalContent) {
          this.insertContentIntoTextarea(finalContent)
        }
      }
    })

    this.eventSource.addEventListener("error", (event) => {
      let errorMsg = "An error occurred"
      try {
        const data = JSON.parse(event.data)
        errorMsg = data.message || errorMsg
      } catch (e) {
        errorMsg = "Connection lost. Please try again."
      }
      this.eventSource.close()
      statusEl.textContent = "Error: " + errorMsg
      spinnerEl.classList.remove("animate-spin")
    })

    this.eventSource.onerror = () => {
      if (this.eventSource.readyState === EventSource.CLOSED) return
      this.eventSource.close()
    }
  }

  escapeHtml(text) {
    const div = document.createElement("div")
    div.textContent = text
    return div.innerHTML
  }
}
