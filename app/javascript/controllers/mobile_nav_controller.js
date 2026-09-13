import { Controller } from "@hotwired/stimulus"

// The panel used to be hidden by transform alone. A translated element is still
// in the tab order, so every link plus Sign out stayed focusable while the panel
// sat off-screen: focus walked into controls nobody could see. `inert` is what
// actually removes a subtree from focus, hit-testing and the accessibility tree,
// and the transform stays purely as the animation.
export default class extends Controller {
  static targets = ["panel", "backdrop", "toggle"]

  connect() {
    this.setInert(true)
  }

  toggle() {
    if (this.panelTarget.classList.contains("-translate-x-full")) {
      this.open()
    } else {
      this.close()
    }
  }

  open() {
    this.previouslyFocused = document.activeElement
    this.panelTarget.classList.remove("-translate-x-full")
    this.backdropTarget.classList.remove("opacity-0", "pointer-events-none")
    document.body.classList.add("overflow-hidden")
    this.setInert(false)
    // Move focus in, so a keyboard user is actually inside the thing that opened.
    this.panelTarget.querySelector("a, button")?.focus()
  }

  close() {
    this.panelTarget.classList.add("-translate-x-full")
    this.backdropTarget.classList.add("opacity-0", "pointer-events-none")
    document.body.classList.remove("overflow-hidden")
    this.setInert(true)
    // Returning focus to the control that opened it, rather than dropping the
    // user back at the top of the document.
    if (this.previouslyFocused?.isConnected) this.previouslyFocused.focus()
    this.previouslyFocused = null
  }

  setInert(inert) {
    this.panelTarget.inert = inert
    if (this.hasToggleTarget) {
      this.toggleTarget.setAttribute("aria-expanded", inert ? "false" : "true")
    }
  }

  closeOnKeydown(event) {
    if (event.key === "Escape" && !this.panelTarget.inert) {
      this.close()
    }
  }

  disconnect() {
    document.body.classList.remove("overflow-hidden")
  }
}
