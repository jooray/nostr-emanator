import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["content", "preview"]

  connect() {
    this.updatePreview()
  }

  updatePreview() {
    const content = this.hasContentTarget ? this.contentTarget.value : ""
    if (!this.hasPreviewTarget) return

    const mediaUrls = this.extractMediaUrls(content)

    if (mediaUrls.length === 0) {
      this.previewTarget.innerHTML = ""
      return
    }

    let html = '<div class="grid grid-cols-2 gap-2 mt-4">'
    for (const url of mediaUrls) {
      if (this.isImage(url)) {
        html += `<img src="${this.escapeHtml(url)}" class="rounded-lg max-h-48 object-cover w-full" loading="lazy" />`
      } else if (this.isVideo(url)) {
        html += `<video src="${this.escapeHtml(url)}" class="rounded-lg max-h-48 w-full" controls preload="metadata"></video>`
      }
    }
    html += '</div>'

    this.previewTarget.innerHTML = html
  }

  extractMediaUrls(text) {
    const urlRegex = /https?:\/\/[^\s]+\.(jpg|jpeg|png|gif|webp|mp4|webm|mov)/gi
    return (text.match(urlRegex) || [])
  }

  isImage(url) {
    return /\.(jpg|jpeg|png|gif|webp)$/i.test(url)
  }

  isVideo(url) {
    return /\.(mp4|webm|mov)$/i.test(url)
  }

  escapeHtml(text) {
    const div = document.createElement('div')
    div.textContent = text
    return div.innerHTML
  }
}
