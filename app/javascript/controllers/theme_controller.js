import { Controller } from "@hotwired/stimulus"
import { t } from "../lib/i18n"

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
    this.updateLabel()
  }

  // The control cycles three states through two icons, so on a dark OS "system"
  // and "dark" rendered identically and the current setting was unknowable.
  // The label states it outright, for the accessible name and the tooltip alike.
  updateLabel() {
    const button = this.element.querySelector("button")
    if (!button) return

    const names = {
      system: t("js.theme.names.system"),
      light: t("js.theme.names.light"),
      dark: t("js.theme.names.dark")
    }
    const next = { system: "light", light: "dark", dark: "system" }
    const label = t("js.theme.label", {
      current: names[this.currentValue],
      next: t(`js.theme.next_names.${next[this.currentValue]}`)
    })
    button.setAttribute("aria-label", label)
    button.setAttribute("title", label)

    const readout = this.element.querySelector("[data-theme-target='readout']")
    if (readout) readout.textContent = names[this.currentValue]
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
