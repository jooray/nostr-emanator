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

    // Show every image whole: a cropped strip of a tall screenshot tells you
    // nothing about what will be posted. One item keeps its own shape; several
    // share equal tiles with the picture fitted inside (letterboxed).
    const single = mediaUrls.length === 1
    const grid = document.createElement("div")
    grid.className = single ? "mt-4" : "grid grid-cols-2 gap-2 mt-4"
    const fit = single
      ? "rounded-lg max-h-96 max-w-full w-auto"
      : "rounded-lg h-56 w-full object-contain bg-black/5 dark:bg-white/5"

    for (const url of mediaUrls) {
      if (this.isImage(url)) {
        const link = document.createElement("a")
        link.href = url
        link.target = "_blank"
        link.rel = "noopener"
        link.className = "block"
        const img = document.createElement("img")
        img.src = url
        img.alt = ""
        img.loading = "lazy"
        img.className = fit
        link.appendChild(img)
        grid.appendChild(link)
      } else if (this.isVideo(url)) {
        const video = document.createElement("video")
        video.src = url
        video.controls = true
        video.preload = "metadata"
        video.className = single ? "rounded-lg max-h-96 max-w-full" : "rounded-lg h-56 w-full bg-black"
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
