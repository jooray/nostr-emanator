import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static values = {
    current: { type: String, default: "system" }
  }

  connect() {
    this.applyTheme()
    this.mediaQuery = window.matchMedia("(prefers-color-scheme: dark)")
    // Bind once and keep the reference — passing a fresh arrow function to
    // removeEventListener (as before) never actually removes anything, so
    // every Turbo visit leaked another listener.
    this.handleMediaQueryChange = () => this.applyTheme()
    this.mediaQuery.addEventListener("change", this.handleMediaQueryChange)
  }

  disconnect() {
    if (this.mediaQuery) {
      this.mediaQuery.removeEventListener("change", this.handleMediaQueryChange)
    }
  }

  toggle() {
    const themes = ["system", "light", "dark"]
    const currentIndex = themes.indexOf(this.currentValue)
    const nextIndex = (currentIndex + 1) % themes.length
    this.currentValue = themes[nextIndex]

    this.applyTheme()
    this.saveTheme()
  }

  applyTheme() {
    const isDark = this.currentValue === "dark" ||
      (this.currentValue === "system" && window.matchMedia("(prefers-color-scheme: dark)").matches)

    document.documentElement.classList.toggle("dark", isDark)
    this.updateIcons(isDark)
  }

  updateIcons(isDark) {
    const sunIcon = this.element.querySelector("[data-theme-icon='sun']")
    const moonIcon = this.element.querySelector("[data-theme-icon='moon']")

    if (sunIcon && moonIcon) {
      sunIcon.classList.toggle("hidden", isDark)
      moonIcon.classList.toggle("hidden", !isDark)
    }
  }

  async saveTheme() {
    try {
      const csrfToken = document.querySelector("meta[name='csrf-token']")?.content

      await fetch("/user", {
        method: "PATCH",
        headers: {
          "Content-Type": "application/json",
          "X-CSRF-Token": csrfToken
        },
        body: JSON.stringify({ theme: this.currentValue })
      })
    } catch (error) {
      console.error("Failed to save theme preference:", error)
    }
  }
}
