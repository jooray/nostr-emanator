import { Controller } from "@hotwired/stimulus"

// "There is also a native Android app": revealed only on Android, and gone for
// good in this browser once dismissed.
const KEY = "android-app-banner-dismissed"

export default class extends Controller {
  connect() {
    if (!/Android/i.test(navigator.userAgent)) return
    try {
      if (localStorage.getItem(KEY)) return
    } catch (e) { /* no storage: show it, dismissal lasts until reload */ }
    this.element.hidden = false
  }

  dismiss() {
    try { localStorage.setItem(KEY, "1") } catch (e) { /* private mode */ }
    this.element.remove()
  }
}
