import { Controller } from "@hotwired/stimulus"
import { t } from "../lib/i18n"

// @mention lookup in the composer, like X: type "@nal" and pick an account.
// Your own accounts come first, then people your accounts follow
// (Mentions::Search, the same lookup the Android app uses). The pick is
// inserted as `nostr:npub…`, which the server turns into a `p` tag when the
// note is signed, so the person is notified.
export default class extends Controller {
  static targets = ["textarea"]
  static values = { url: String }

  connect() {
    this.menu = document.createElement("ul")
    this.menu.setAttribute("role", "listbox")
    this.menu.className = "absolute z-30 hidden max-h-72 w-72 overflow-y-auto rounded-lg border border-gray-200 dark:border-[color:var(--color-rule-dark)] bg-white dark:bg-gray-900 shadow-lg py-1 text-sm"
    this.element.appendChild(this.menu)
    this.items = []
    this.active = 0
    this.seq = 0
  }

  disconnect() {
    clearTimeout(this.timer)
    this.menu.remove()
  }

  input() {
    const token = this.token()
    if (!token) return this.close()
    clearTimeout(this.timer)
    this.timer = setTimeout(() => this.lookup(token), 120)
  }

  keydown(event) {
    if (this.menu.classList.contains("hidden")) return
    if (event.key === "ArrowDown" || event.key === "ArrowUp") {
      event.preventDefault()
      const step = event.key === "ArrowDown" ? 1 : -1
      this.highlight((this.active + step + this.items.length) % this.items.length)
    } else if (event.key === "Enter" || event.key === "Tab") {
      event.preventDefault()
      this.pick(this.items[this.active])
    } else if (event.key === "Escape") {
      event.preventDefault()
      this.close()
    }
  }

  blur() {
    // Let a click on the menu land first.
    setTimeout(() => this.close(), 150)
  }

  // The "@word" being typed right before the caret, or null.
  token() {
    const el = this.textareaTarget
    if (el.selectionStart !== el.selectionEnd) return null
    const before = el.value.slice(0, el.selectionStart)
    const match = before.match(/(?:^|\s)@([\p{L}\p{N}_.-]{0,30})$/u)
    if (!match) return null
    return { query: match[1], start: el.selectionStart - match[1].length - 1, end: el.selectionStart }
  }

  async lookup(token) {
    const seq = ++this.seq
    let mentions = []
    try {
      const url = `${this.urlValue}?q=${encodeURIComponent(token.query)}`
      const response = await fetch(url, { headers: { Accept: "application/json" }, credentials: "same-origin" })
      if (response.ok) mentions = (await response.json()).mentions || []
    } catch {
      mentions = []
    }
    if (seq !== this.seq) return
    this.token_ = token
    this.items = mentions
    if (mentions.length === 0) return this.close()
    this.render()
  }

  render() {
    this.menu.replaceChildren()
    this.items.forEach((m, index) => {
      const li = document.createElement("li")
      li.setAttribute("role", "option")
      li.className = "flex items-center gap-2 px-3 py-2 cursor-pointer"
      li.addEventListener("mousedown", (e) => { e.preventDefault(); this.pick(m) })
      li.addEventListener("mouseenter", () => this.highlight(index))

      if (m.picture_url) {
        const img = document.createElement("img")
        img.src = m.picture_url
        img.alt = ""
        img.className = "h-7 w-7 flex-none rounded-full object-cover"
        li.appendChild(img)
      } else {
        const dot = document.createElement("span")
        dot.className = "h-7 w-7 flex-none rounded-full bg-amber-500/20 text-amber-700 dark:text-amber-400 flex items-center justify-center text-xs font-semibold"
        dot.textContent = (m.display_name || m.name || "?").slice(0, 1).toUpperCase()
        li.appendChild(dot)
      }

      const text = document.createElement("span")
      text.className = "min-w-0 flex-1"
      const title = document.createElement("span")
      title.className = "block truncate font-medium text-gray-900 dark:text-gray-100"
      title.textContent = m.display_name || m.name || m.npub.slice(0, 16)
      const sub = document.createElement("span")
      sub.className = "block truncate text-xs text-gray-500 dark:text-gray-400"
      sub.textContent = m.own ? t("js.mention.own") : (m.nip05 || (m.name ? `@${m.name}` : m.npub.slice(0, 20) + "…"))
      text.append(title, sub)
      li.appendChild(text)
      this.menu.appendChild(li)
    })
    this.highlight(0)
    this.place()
    this.menu.classList.remove("hidden")
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

  pick(mention) {
    if (!mention || !this.token_) return
    const el = this.textareaTarget
    const { start, end } = this.token_
    const after = el.value.slice(end)
    const insert = mention.mention + (after.startsWith(" ") || after.startsWith("\n") ? "" : " ")
    el.setRangeText(insert, start, end, "end")
    el.focus()
    el.dispatchEvent(new Event("input", { bubbles: true }))
    this.close()
  }

  close() {
    this.seq++
    this.items = []
    this.token_ = null
    this.menu.classList.add("hidden")
  }

  // Puts the menu just under the caret line, using a hidden mirror of the
  // textarea to find where the caret is drawn.
  place() {
    const el = this.textareaTarget
    const style = getComputedStyle(el)
    const mirror = document.createElement("div")
    for (const prop of ["boxSizing", "width", "fontFamily", "fontSize", "fontWeight", "lineHeight", "letterSpacing",
      "paddingTop", "paddingRight", "paddingBottom", "paddingLeft", "borderTopWidth", "borderLeftWidth", "wordSpacing", "tabSize"]) {
      mirror.style[prop] = style[prop]
    }
    mirror.style.position = "absolute"
    mirror.style.visibility = "hidden"
    mirror.style.whiteSpace = "pre-wrap"
    mirror.style.overflowWrap = "break-word"
    mirror.textContent = el.value.slice(0, this.token_.start)
    const marker = document.createElement("span")
    marker.textContent = "@"
    mirror.appendChild(marker)
    document.body.appendChild(mirror)
    const lineHeight = parseFloat(style.lineHeight) || parseFloat(style.fontSize) * 1.4
    const top = el.offsetTop + marker.offsetTop - el.scrollTop + lineHeight + 4
    // The menu is 18rem wide unless the field is narrower (a phone, or the
    // account page's reply box); never let it overhang the field.
    const width = Math.min(288, el.clientWidth || 288)
    this.menu.style.width = `${width}px`
    const maxLeft = el.offsetLeft + el.clientWidth - width
    const left = Math.max(el.offsetLeft, Math.min(el.offsetLeft + marker.offsetLeft, maxLeft))
    mirror.remove()
    this.menu.style.top = `${top}px`
    this.menu.style.left = `${left}px`
  }
}
