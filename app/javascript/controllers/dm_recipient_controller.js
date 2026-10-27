import { Controller } from "@hotwired/stimulus"
import { t } from "../lib/i18n"

// The recipient field of the "New message" page. Same lookup as the composer's
// @mention (Mentions::Search, plus people you already message): your own
// accounts, then people your accounts follow, by name, NIP-05 or a pasted
// npub / nprofile. The pick fills a hidden `recipient` field and becomes a chip.
export default class extends Controller {
  static targets = ["query", "value", "chip", "chipImage", "chipName", "chipSub", "search", "submit"]
  static values = { url: String }

  connect() {
    this.menu = document.createElement("ul")
    this.menu.setAttribute("role", "listbox")
    this.menu.className = "absolute left-0 right-0 z-30 mt-1 hidden max-h-80 overflow-y-auto rounded-lg border border-gray-200 dark:border-[color:var(--color-rule-dark)] bg-white dark:bg-gray-900 shadow-lg py-1 text-sm"
    this.searchTarget.appendChild(this.menu)
    this.items = []
    this.active = 0
    this.seq = 0
    this.sync()
  }

  disconnect() {
    clearTimeout(this.timer)
    this.menu.remove()
  }

  input() {
    clearTimeout(this.timer)
    const query = this.queryTarget.value.trim()
    if (!query) return this.close()
    this.timer = setTimeout(() => this.lookup(query), 150)
  }

  keydown(event) {
    const open = !this.menu.classList.contains("hidden")
    if (event.key === "Enter") {
      // Enter picks; it must never submit a form that has no recipient yet.
      event.preventDefault()
      if (open) this.pick(this.items[this.active])
      return
    }
    if (!open) return
    if (event.key === "ArrowDown" || event.key === "ArrowUp") {
      event.preventDefault()
      const step = event.key === "ArrowDown" ? 1 : -1
      this.highlight((this.active + step + this.items.length) % this.items.length)
    } else if (event.key === "Escape") {
      event.preventDefault()
      this.close()
    }
  }

  blur() {
    setTimeout(() => this.close(), 150)
  }

  async lookup(query) {
    const seq = ++this.seq
    let people = []
    try {
      const url = new URL(this.urlValue, window.location.origin)
      url.searchParams.set("q", query)
      const response = await fetch(url, { headers: { Accept: "application/json" }, credentials: "same-origin" })
      if (response.ok) people = (await response.json()).mentions || []
    } catch {
      people = []
    }
    if (seq !== this.seq) return
    this.items = people
    this.render()
  }

  render() {
    this.menu.replaceChildren()
    if (this.items.length === 0) {
      const li = document.createElement("li")
      li.className = "px-3 py-2 text-gray-500 dark:text-gray-400"
      li.textContent = t("js.dm_recipient.no_match")
      this.menu.appendChild(li)
    }
    this.items.forEach((m, index) => {
      const li = document.createElement("li")
      li.setAttribute("role", "option")
      li.className = "flex items-center gap-2 px-3 py-2 cursor-pointer"
      li.addEventListener("mousedown", (e) => { e.preventDefault(); this.pick(m) })
      li.addEventListener("mouseenter", () => this.highlight(index))
      li.appendChild(this.avatar(m))

      const text = document.createElement("span")
      text.className = "min-w-0 flex-1"
      const title = document.createElement("span")
      title.className = "block truncate font-medium text-gray-900 dark:text-gray-100"
      title.textContent = this.label(m)
      const sub = document.createElement("span")
      sub.className = "block truncate text-xs text-gray-500 dark:text-gray-400"
      sub.textContent = m.own ? t("js.mention.own") : (m.nip05 || (m.name ? `@${m.name}` : m.npub.slice(0, 20) + "…"))
      text.append(title, sub)
      li.appendChild(text)
      this.menu.appendChild(li)
    })
    this.highlight(0)
    this.menu.classList.remove("hidden")
    this.queryTarget.setAttribute("aria-expanded", "true")
  }

  avatar(m) {
    if (m.picture_url) {
      const img = document.createElement("img")
      img.src = m.picture_url
      img.alt = ""
      img.className = "h-7 w-7 flex-none rounded-full object-cover"
      return img
    }
    const dot = document.createElement("span")
    dot.className = "h-7 w-7 flex-none rounded-full bg-amber-500/20 text-amber-700 dark:text-amber-400 flex items-center justify-center text-xs font-semibold"
    dot.textContent = this.label(m).slice(0, 1).toUpperCase()
    return dot
  }

  label(m) {
    return m.display_name || m.name || m.npub.slice(0, 16)
  }

  highlight(index) {
    this.active = index
    Array.from(this.menu.children).forEach((li, i) => {
      li.classList.toggle("bg-amber-50", i === index)
      li.classList.toggle("dark:bg-amber-500/10", i === index)
      li.setAttribute("aria-selected", i === index ? "true" : "false")
    })
    this.menu.children[index]?.scrollIntoView({ block: "nearest" })
  }

  pick(person) {
    if (!person) return
    this.valueTarget.value = person.npub
    this.chipNameTarget.textContent = this.label(person)
    this.chipSubTarget.textContent = person.nip05 || person.npub
    if (person.picture_url) {
      this.chipImageTarget.src = person.picture_url
      this.chipImageTarget.classList.remove("hidden")
    } else {
      this.chipImageTarget.classList.add("hidden")
    }
    this.close()
    this.sync()
    this.element.querySelector("textarea")?.focus()
  }

  clear() {
    this.valueTarget.value = ""
    this.queryTarget.value = ""
    this.sync()
    this.queryTarget.focus()
  }

  // Chip or search box, and Send only once someone is chosen.
  sync() {
    const chosen = this.valueTarget.value !== ""
    this.chipTarget.classList.toggle("hidden", !chosen)
    this.searchTarget.classList.toggle("hidden", chosen)
    if (this.hasSubmitTarget) this.submitTarget.disabled = !chosen
  }

  close() {
    this.seq++
    this.items = []
    this.menu.classList.add("hidden")
    this.queryTarget.setAttribute("aria-expanded", "false")
  }
}
