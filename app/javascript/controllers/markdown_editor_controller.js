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

    const form = this.element.closest("form")
    if (form) {
      form.addEventListener("submit", () => {
        this.textareaTarget.value = this.editor.value()
      })
    }
  }

  disconnect() {
    if (this.editor) {
      this.editor.toTextArea()
      this.editor = null
    }
  }
}
