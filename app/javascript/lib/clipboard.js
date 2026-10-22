// Copying text for the networks that give us no way to prefill it.
//
// Browsers only let a page put text on the clipboard (navigator.clipboard) or
// open a URL; Facebook and LinkedIn have no intent URL that accepts a post's
// text, so a share there is "copy the note, open their composer, paste".
// navigator.clipboard still needs the user gesture, hence the copy runs first
// and the tab opens in the same task.
export async function copyText(text) {
  if (navigator.clipboard?.writeText) return navigator.clipboard.writeText(text)
  legacyCopy(text)
}

// execCommand("copy") is deprecated but still the only path when the async
// clipboard API is unavailable (an insecure context, an old browser).
export function legacyCopy(text) {
  const textarea = document.createElement("textarea")
  textarea.value = text
  textarea.style.position = "fixed"
  textarea.style.opacity = "0"
  document.body.appendChild(textarea)
  textarea.focus()
  textarea.select()
  const succeeded = document.execCommand("copy")
  textarea.remove()
  if (!succeeded) throw new Error("execCommand('copy') failed")
}
