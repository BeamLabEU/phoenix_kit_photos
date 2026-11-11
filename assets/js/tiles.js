// What is inside a tile: the picture and the little things around it.

import { offeredPreview } from "./upload_previews.js"

const SHARP_ENOUGH = 0.75

/** A tilt for a paper print, the same each time for the same photo. */
function tilt(id) {
  let hash = 0
  for (let i = 0; i < id.length; i++) hash = (hash * 31 + id.charCodeAt(i)) | 0
  return (((hash >>> 0) % 500) / 100 - 2.5).toFixed(2)
}

function span(className, text) {
  const node = document.createElement("span")
  node.className = className
  if (text) node.textContent = text
  return node
}

function formatDate(iso, options) {
  if (!iso) return ""
  const date = new Date(iso)
  if (Number.isNaN(date.getTime())) return ""
  try {
    return new Intl.DateTimeFormat(document.documentElement.lang || undefined, options).format(date)
  } catch (_error) {
    return date.toDateString()
  }
}

function formatBytes(bytes) {
  if (!Number.isFinite(bytes) || bytes <= 0) return ""
  const units = ["B", "KB", "MB", "GB"]
  const power = Math.min(units.length - 1, Math.floor(Math.log(bytes) / Math.log(1024)))
  const value = bytes / 1024 ** power
  return `${value >= 10 || power === 0 ? Math.round(value) : value.toFixed(1)} ${units[power]}`
}

function formatDuration(seconds) {
  if (!Number.isFinite(seconds) || seconds <= 0) return ""
  const whole = Math.round(seconds)
  return `${Math.floor(whole / 60)}:${String(whole % 60).padStart(2, "0")}`
}

/** Build a new tile's insides. Every style shows some of these; the sheet says which. */
export function fillTile(node, item) {
  node.dataset.kind = item.kind || "image"
  node.style.setProperty("--pkt-tilt", `${tilt(item.id)}deg`)

  const paper = span("pkt-paper")
  const img = document.createElement("img")
  img.alt = ""
  // Eager, not lazy: the grid builds tiles for what is on screen only, so there is nothing to
  // put off, and Safari leaves a lazy image inside a scrolling element unloaded until that
  // element scrolls. A tile given its picture without a scroll (the grid redrawn as the viewer
  // closes) stayed blank there.
  img.loading = "eager"
  img.decoding = "async"
  img.draggable = false
  paper.appendChild(img)

  const date = formatDate(item.taken_at, { day: "numeric", month: "short", year: "numeric" })
  const caption = span("pkt-caption", date)

  const facts = [
    formatDate(item.taken_at, { dateStyle: "medium", timeStyle: "short" }),
    formatBytes(item.size),
    item.w && item.h ? `${item.w} × ${item.h}` : ""
  ]
  const meta = span("pkt-meta")
  meta.append(span("pkt-name", item.name || date), span("pkt-sub", facts.filter(Boolean).join(" · ")))

  // Shown only while the file's sizes are being made (`markPending`).
  paper.appendChild(span("pkt-pending"))

  node.append(
    paper,
    caption,
    meta,
    span("pkt-badge", formatDuration(item.duration)),
    span("pkt-stack"),
    span("pkt-check")
  )
}

/**
 * A tile that stands for a stack (`item.stack`: its id, how many photos, its title) wears
 * a badge with the count, says so in its label, and in the styles that list names shows
 * the stack's title. Called on every placement: a tile is reused when its photo is
 * stacked or unstacked. `label` is the translated "Stack of %{count} photos".
 */
export function markStack(node, item, label = "Stack of %{count} photos") {
  const stack = item.stack && item.stack.count >= 2 ? item.stack : null
  const badge = node.querySelector(".pkt-stack")
  const name = node.querySelector(".pkt-name")

  if (stack) {
    node.dataset.stack = stack.id
    if (badge) badge.textContent = String(stack.count)
    const what = label.replace("%{count}", String(stack.count))
    node.setAttribute("aria-label", stack.title ? `${stack.title} · ${what}` : what)
    node.title = stack.title || ""
    if (name) name.textContent = stack.title || item.name || name.textContent
  } else if (node.dataset.stack !== undefined) {
    delete node.dataset.stack
    if (badge) badge.textContent = ""
    node.setAttribute("aria-label", item.kind === "video" ? "Open video" : "Open photo")
    node.removeAttribute("title")
    if (name && item.name) name.textContent = item.name
  }
}

/**
 * A file whose sizes are still being made has a tile and no picture of its own: the tile is
 * marked (the sheet draws it as being prepared) and shows the picture the uploader made in
 * this browser, when this is the page that uploaded it.
 */
export function markPending(node, item) {
  if (item.pending === true) node.dataset.pending = ""
  else delete node.dataset.pending
}

/**
 * Which of a file's pictures to show in a tile of `w` by `h` px. The square crop is the lightest,
 * but cannot fill a tile of another shape; among those that keep the shape, take the smallest
 * that is sharp enough at this screen's density.
 */
export function pickSource(item, w, h, style, density = 1) {
  if (item.pending) return offeredPreview(item.id)
  const need = Math.max(w, h) * density * SHARP_ENOUGH
  const square = Math.abs(w - h) < 2 || style.crop && Math.max(w, h) / Math.min(w, h) < 1.25
  if (square && need <= 340 && item.thumb) return item.thumb
  if (need <= 300 && item.fit) return item.fit
  if (need <= 820 && item.preview) return item.preview
  return item.large || item.preview || item.fit || item.thumb
}

/**
 * Change a tile's picture without a flash: the new one loads out of sight on top of the old, fades
 * in, and the old one goes.
 */
export function swapImage(node, img, src) {
  if (img.dataset.next === src) return
  img.dataset.next = src
  const next = img.cloneNode()
  next.src = src
  next.dataset.src = src
  delete next.dataset.next
  next.loading = "eager"
  next.style.opacity = "0"
  const show = () => {
    if (img.dataset.next !== src || !img.isConnected) {
      next.remove()
      return
    }
    next.style.opacity = ""
    if (next.animate) {
      next.animate([{ opacity: 0 }, { opacity: 1 }], { duration: 220 }).finished
        .then(() => img.remove(), () => img.remove())
    } else {
      img.remove()
    }
  }
  img.parentNode.appendChild(next)
  next.decode ? next.decode().then(show, () => next.remove()) : (next.onload = show)
}
