// A link pasted into a library: the photos and videos it points at are fetched on the
// server (`PhoenixKitPhotos.Components.LinkFetcher`). The pure functions say what counts
// as a pasted link; the hook only wires them up.
//
// A paste anywhere on the page but in a text field, carrying text and no files, whose
// text is one http(s) link, is handed to the component ("paste_link"). A paste that
// carries files is the uploader's (`photo_uploader.js`), and the two never both act.
// The uploader's Paste button (an iPad sends no paste event) reads the clipboard
// itself; when it finds a link and no picture, it hands the link here as the DOM event
// `phoenix-kit-photos:link` on `document`.

import { carriesPastedFiles, isEditable } from "./paste_files.js"

export const LINK_EVENT = "phoenix-kit-photos:link"

const URL_RE = /https?:\/\/[^\s<>"'`]+/gi

/**
 * The one http(s) link in `text`, or null when it holds none or several. Punctuation a
 * sentence put after the link is dropped. The server checks it again (`Fetches.Link`).
 */
export function linkIn(text) {
  if (typeof text !== "string") return null
  const found = text.trim().match(URL_RE)
  if (!found || found.length !== 1) return null
  let url = found[0].replace(/[.,;:!?]+$/, "")
  if (url.endsWith(")") && !url.includes("(")) url = url.slice(0, -1)
  return url
}

/** The link a paste event carries, or null (files, no text, not one link). */
export function linkFromPaste(clipboardData) {
  if (!clipboardData || carriesPastedFiles(clipboardData)) return null
  const text = typeof clipboardData.getData === "function" ? clipboardData.getData("text/plain") : ""
  return linkIn(text)
}

/** The link among clipboard items read on request (`navigator.clipboard.read()`), or null. */
export async function linkFromClipboardItems(items) {
  for (const item of items || []) {
    const types = Array.from((item && item.types) || [])
    if (!types.includes("text/plain")) continue
    try {
      const blob = await item.getType("text/plain")
      const link = linkIn(await blob.text())
      if (link) return link
    } catch (_error) {
      // a text it could not read is no link
    }
  }
  return null
}

export const LinkFetcher = {
  mounted() {
    this.onPaste = event => {
      if (event.defaultPrevented || isEditable(event.target)) return
      const link = linkFromPaste(event.clipboardData)
      if (!link) return
      event.preventDefault()
      this.pushEventTo(this.el, "paste_link", { text: link })
    }

    this.onLink = event => {
      const link = linkIn(event.detail && event.detail.text)
      if (link) this.pushEventTo(this.el, "paste_link", { text: link })
    }

    window.addEventListener("paste", this.onPaste)
    document.addEventListener(LINK_EVENT, this.onLink)
  },

  destroyed() {
    window.removeEventListener("paste", this.onPaste)
    document.removeEventListener(LINK_EVENT, this.onLink)
  }
}
