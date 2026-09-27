import { Controller } from "@hotwired/stimulus"
import flatpickr from "flatpickr"
import { Slovak } from "flatpickr/dist/l10n/sk.js"
import { Czech } from "flatpickr/dist/l10n/cs.js"
import { Spanish } from "flatpickr/dist/l10n/es.js"
import { locale } from "../lib/i18n"

// Month/day names and the date order the picker shows, per interface language.
const PICKER_LOCALES = {
  sk: { l10n: Slovak, date: "j. F Y" },
  cs: { l10n: Czech, date: "j. F Y" },
  es: { l10n: Spanish, date: "j F Y" }
}

export default class extends Controller {
  static targets = ["datetimeInput", "delayInput", "timezoneInput"]
  static values = { suggestedTime: String, soonMinutes: { type: Number, default: 7 } }

  connect() {
    // The submitted zone, so the picked wall-clock time is parsed against the
    // clock the user read it on. Persisting the zone is local_time_controller's
    // job now — it runs on <body>, so it learns the zone on every page instead
    // of only this one.
    if (this.hasTimezoneInputTarget) {
      this.timezoneInputTarget.value = Intl.DateTimeFormat().resolvedOptions().timeZone
    }

    // Detect 12h vs 24h from locale
    const is24h = this.is24h()
    const picker = PICKER_LOCALES[locale()]

    // Initialize flatpickr
    if (this.hasDatetimeInputTarget) {
      this.picker = flatpickr(this.datetimeInputTarget, {
        enableTime: true,
        dateFormat: "Y-m-dTH:i",
        altInput: true,
        altFormat: picker
          ? `${picker.date} ${is24h ? "H:i" : "h:i K"}`
          : (is24h ? "F j, Y H:i" : "F j, Y h:i K"),
        ...(picker ? { locale: picker.l10n } : {}),
        time_24hr: is24h,
        minDate: "today",
        defaultDate: this.suggestedTimeValue || null
      })
    }
  }

  disconnect() {
    this.picker?.destroy()
  }

  useSuggestion(event) {
    event.preventDefault()
    const time = event.currentTarget.dataset.time
    if (time && this.picker) {
      this.picker.setDate(time, true)
    }
  }

  useSoon(event) {
    event.preventDefault()
    if (!this.picker) return
    const soon = new Date(Date.now() + this.soonMinutesValue * 60 * 1000)
    // The picker has minute precision; round up so truncation never eats into
    // the margin left for signing.
    if (soon.getSeconds() > 0 || soon.getMilliseconds() > 0) {
      soon.setSeconds(0, 0)
      soon.setMinutes(soon.getMinutes() + 1)
    }
    this.picker.setDate(soon, true)
  }

  toggleReposts(event) {
    const checkboxes = document.querySelectorAll("[data-repost-checkbox]")
    checkboxes.forEach(cb => cb.checked = event.currentTarget.checked)
  }

  is24h() {
    try {
      const formatted = new Intl.DateTimeFormat(locale(), { hour: "numeric" })
        .format(new Date(2000, 0, 1, 13))
      return !formatted.match(/[AP]M/i)
    } catch {
      return true
    }
  }
}
