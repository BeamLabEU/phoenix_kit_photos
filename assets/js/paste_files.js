// What a paste carries, as files. Pure functions over the browser's clipboard shapes,
// so they are testable without a browser; the uploader's hook only wires them up.
//
// A paste is one of two things. Files copied in a file manager (Finder, Explorer, a
// Linux desktop) arrive as files with their own names, as many as were copied in the
// browsers that pass them all on; they go through the same path as a drop
// (`filesFromDrop`), folders included where the browser offers them. An image copied
// from a page, an app or a screenshot tool arrives as ONE file the browser made up,
// named `image.png` every time: it is renamed `Pasted_<local time>.png`, so pastes are
// told apart in the library and core dates it from the name (a pasted image carries no
// EXIF, and a name's date is read as the local wall-clock time).

import { acceptable, filesFromDrop } from "./drop_files.js"

/** Whether a paste carries files (not only text). */
export function carriesPastedFiles(clipboardData) {
  if (!clipboardData) return false
  if (clipboardData.files && clipboardData.files.length > 0) return true
  const items = clipboardData.items ? Array.from(clipboardData.items) : []
  return items.some(item => item.kind === "file")
}

/**
 * Whether a paste aimed here belongs to a text field: an input other than a file
 * input, a textarea, a select or anything editable keeps its paste.
 */
export function isEditable(target) {
  if (!target || typeof target.closest !== "function") return false
  if (target.isContentEditable) return true
  const field = target.closest("input, textarea, select, [contenteditable]:not([contenteditable=false])")
  if (!field) return false
  const tag = String(field.tagName || "").toLowerCase()
  if (tag === "input") return String(field.type || "").toLowerCase() !== "file"
  return true
}

// A file a browser made from clipboard image data, not a file from a disk: every
// browser calls it `image.<ext>` (or nothing), and dates it the moment of the paste.
// A real `image.png` copied from a folder keeps its name: it was not modified just now.
const MADE_UP_NAME = /^image\.[a-z0-9]+$/i
const JUST_NOW_MS = 60_000

/** Whether `file` is an image the browser made up from the clipboard. */
export function madeUp(file, now = Date.now()) {
  const name = String((file && file.name) || "")
  if (name !== "" && !MADE_UP_NAME.test(name)) return false
  const at = Number(file && file.lastModified)
  return !Number.isFinite(at) || Math.abs(now - at) <= JUST_NOW_MS
}

const TYPE_EXTENSIONS = {
  "image/png": ".png",
  "image/jpeg": ".jpg",
  "image/gif": ".gif",
  "image/webp": ".webp",
  "image/avif": ".avif",
  "image/heic": ".heic",
  "image/heif": ".heif",
  "image/tiff": ".tiff",
  "image/bmp": ".bmp",
  "image/svg+xml": ".svg"
}

const pad = (n, width = 2) => String(n).padStart(width, "0")

/**
 * The name a made-up image is given: `Pasted_20261111_143005.png`, the local time of
 * the paste, with `_2`, `_3`… after the first when one paste carries several.
 */
export function pastedName(file, date, index = 0) {
  const name = String((file && file.name) || "")
  const dot = name.lastIndexOf(".")
  const ext = dot > 0 ? name.slice(dot).toLowerCase() : TYPE_EXTENSIONS[String(file && file.type).toLowerCase()] || ".png"
  const stamp =
    `${date.getFullYear()}${pad(date.getMonth() + 1)}${pad(date.getDate())}_` +
    `${pad(date.getHours())}${pad(date.getMinutes())}${pad(date.getSeconds())}`
  return `Pasted_${stamp}${index > 0 ? `_${index + 1}` : ""}${ext}`
}

/** `file` under a new name, its bytes, type and date unchanged. */
function renamed(file, name) {
  return new File([file], name, { type: file.type, lastModified: file.lastModified })
}

/**
 * The files of a paste, as `filesFromDrop` gives them (`{ files, skipped, unreadable,
 * truncated }`), each image the browser made up renamed (see the top of this file).
 * Must be CALLED inside the paste handler, for the same reason as a drop.
 */
export async function filesFromPaste(clipboardData, { accept = null, limit = 20000, now = new Date() } = {}) {
  const result = await filesFromDrop(clipboardData, { accept, limit })
  let made = 0
  const files = result.files.map(file => (madeUp(file, now.getTime()) ? renamed(file, pastedName(file, now, made++)) : file))
  return { ...result, files }
}

// The uploader's Paste button. A paste event never reaches a page on an iPad without a
// keyboard: iOS offers Paste only on something one types into. So the button asks for
// the clipboard itself (`navigator.clipboard.read()`, inside the tap: Safari then shows
// its own Paste bubble, Chrome asks for permission once, Firefox shows a Paste menu).
// What comes back is a list of ClipboardItems, each with its types; only images can be
// read this way (files copied in a file manager are not offered), and each becomes one
// file named like a pasted image.

/** Whether this browser can read the clipboard when asked, outside a paste event. */
export function canReadClipboard(nav = globalThis.navigator) {
  return Boolean(nav && nav.clipboard && typeof nav.clipboard.read === "function")
}

/**
 * The images of a clipboard read (`navigator.clipboard.read()`), as `filesFromDrop`
 * gives files: `{ files, skipped, unreadable, truncated }`. An item is one image in the
 * first of its types this page takes; an image of a kind it does not take, or one that
 * cannot be read, is counted as skipped, and an item with no image (text, a link) is
 * left alone.
 */
export async function filesFromClipboard(items, { accept = null, now = new Date() } = {}) {
  const files = []
  let skipped = 0

  for (const item of items || []) {
    const images = Array.from((item && item.types) || []).filter(type => TYPE_EXTENSIONS[String(type).toLowerCase()])
    if (images.length === 0) continue

    const index = files.length
    const type = images.find(type => acceptable(pastedName({ type }, now, index), accept))
    if (!type) {
      skipped += 1
      continue
    }

    try {
      const blob = await item.getType(type)
      const name = pastedName({ type }, now, index)
      files.push(new File([blob], name, { type: blob.type || type, lastModified: now.getTime() }))
    } catch (_error) {
      skipped += 1
    }
  }

  return { files, skipped, unreadable: 0, truncated: false }
}
