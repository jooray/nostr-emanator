import { Controller } from "@hotwired/stimulus"
import EasyMDE from "easymde"

export default class extends Controller {
  static targets = ["textarea"]
  static values = { placeholder: String }

  connect() {
    const placeholder = this.hasPlaceholderValue
      ? this.placeholderValue
      : "Type your content here..."

    this.editor = new EasyMDE({
      element: this.textareaTarget,
      spellChecker: false,
      autosave: { enabled: false },
      toolbar: [
        "bold", "italic", "heading", "|",
        "quote", "unordered-list", "ordered-list", "|",
        "link", "|",
        "preview", "side-by-side", "fullscreen", "|",
        "guide"
      ],
      status: false,
      minHeight: "300px",
      placeholder: placeholder,
      renderingConfig: {
        singleLineBreaks: false,
        codeSyntaxHighlighting: false
      }
    })

    this.form = this.element.closest("form")
    if (this.form) {
      // Keep the reference so disconnect() can remove this exact listener —
      // otherwise a Turbo-cache restore re-runs connect() and stacks up a
      // duplicate submit handler on the same form every time.
      this.handleSubmit = () => { this.textareaTarget.value = this.editor.value() }
      this.form.addEventListener("submit", this.handleSubmit)
    }
  }

  disconnect() {
    if (this.form && this.handleSubmit) {
      this.form.removeEventListener("submit", this.handleSubmit)
    }
    if (this.editor) {
      this.editor.toTextArea()
      this.editor = null
    }
  }
}
