import { Controller } from "@hotwired/stimulus"
import flatpickr from "flatpickr"

export default class extends Controller {
  static targets = ["datetimeInput", "delayInput", "timezoneInput"]
  static values = { suggestedTime: String }

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

    // Initialize flatpickr
    if (this.hasDatetimeInputTarget) {
      this.picker = flatpickr(this.datetimeInputTarget, {
        enableTime: true,
        dateFormat: "Y-m-dTH:i",
        altInput: true,
        altFormat: is24h ? "F j, Y H:i" : "F j, Y h:i K",
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

  toggleReposts(event) {
    const checkboxes = document.querySelectorAll("[data-repost-checkbox]")
    checkboxes.forEach(cb => cb.checked = event.currentTarget.checked)
  }

  is24h() {
    try {
      const formatted = new Intl.DateTimeFormat(undefined, { hour: "numeric" })
        .format(new Date(2000, 0, 1, 13))
      return !formatted.match(/[AP]M/i)
    } catch {
      return true
    }
  }
}
