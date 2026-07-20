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

    // Build with DOM APIs (property assignment) rather than interpolating the
    // URL into an HTML string — a URL containing a stray quote could otherwise
    // break out of the src="..." attribute.
    this.previewTarget.replaceChildren()
    if (mediaUrls.length === 0) return

    const grid = document.createElement("div")
    grid.className = "grid grid-cols-2 gap-2 mt-4"

    for (const url of mediaUrls) {
      if (this.isImage(url)) {
        const img = document.createElement("img")
        img.src = url
        img.alt = ""
        img.loading = "lazy"
        img.className = "rounded-lg max-h-48 object-cover w-full"
        grid.appendChild(img)
      } else if (this.isVideo(url)) {
        const video = document.createElement("video")
        video.src = url
        video.controls = true
        video.preload = "metadata"
        video.className = "rounded-lg max-h-48 w-full"
        grid.appendChild(video)
      }
    }

    this.previewTarget.appendChild(grid)
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
}
