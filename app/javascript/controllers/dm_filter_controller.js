import { Controller } from "@hotwired/stimulus"

// Account filter pills on the Messages inbox.
//
// Deliberately submits the form rather than hiding rows client-side, which is
// what interactions_filter_controller does. That approach breaks with
// pagination: filtering a 30-row page in the browser leaves short and sometimes
// empty pages, and the counts stop matching what is on screen.
export default class extends Controller {
  static targets = ["form"]

  apply() {
    this.formTarget.requestSubmit()
  }
}
