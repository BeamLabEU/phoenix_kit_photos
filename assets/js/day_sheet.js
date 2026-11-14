// A day of the calendar, opened: a sheet over the month (which stays, dimmed, behind) with
// all of that day's photos as a grid, ‹ › to the day before and after that has photos, and ✕.
// It only draws and reports: the timeline hook (photo_timeline.js) knows the days, fetches
// their photos, keeps the address, and opens the swipe viewer over the sheet on a tile.
//
//   const sheet = new DaySheet({ strings, lang, onClose, onStep, onOpen })
//   sheet.show(day, { prev, next })   // day: { date, start, count } (days.js)
//   sheet.fill(items)                 // the day's items, in order, as they arrive
//   sheet.imgOf(id)                   // a tile's <img>, for the viewer to fly back to
//   sheet.hide(); sheet.destroy()
//
// It lives in <body>, outside LiveView's DOM, as the swipe viewer does.

import { pickSource } from "./tiles.js"

const TILE = 160

function element(tag, className, attrs = {}) {
  const node = document.createElement(tag)
  if (className) node.className = className
  for (const [name, value] of Object.entries(attrs)) node.setAttribute(name, value)
  return node
}

function duration(seconds) {
  if (!Number.isFinite(seconds) || seconds <= 0) return ""
  const whole = Math.round(seconds)
  return `${Math.floor(whole / 60)}:${String(whole % 60).padStart(2, "0")}`
}

/** "Thursday, 24 February 2022" in the page's language. */
export function dayLabel(date, lang) {
  const [y, m, d] = date.split("-").map(Number)
  const at = new Date(Date.UTC(y, m - 1, d))
  const options = { weekday: "long", day: "numeric", month: "long", year: "numeric", timeZone: "UTC" }
  try {
    return new Intl.DateTimeFormat(lang || undefined, options).format(at)
  } catch (_error) {
    return new Intl.DateTimeFormat(undefined, options).format(at)
  }
}

/** "13 photos" / "1 photo" from the page's strings. */
export function countLabel(count, strings = {}) {
  if (count === 1) return strings.one || "1 photo"
  return (strings.day || "%{count} photos").replace("%{count}", String(count))
}

export class DaySheet {
  constructor({ strings = {}, lang, onClose, onStep, onOpen }) {
    this.strings = strings
    this.lang = lang
    this.onClose = onClose
    this.onStep = onStep
    this.onOpen = onOpen
    this.day = null
    this.tiles = new Map()
    this.onKey = (event) => this.key(event)
  }

  get isOpen() {
    return this.day !== null
  }

  build() {
    if (this.root) return
    const id = `pkt-sheet-${Math.random().toString(36).slice(2, 8)}`
    this.backdrop = element("div", "pkt-sheet-backdrop")
    this.backdrop.addEventListener("click", () => this.onClose && this.onClose())

    this.root = element("section", "pkt-sheet", { role: "dialog", "aria-modal": "true", "aria-labelledby": `${id}-title`, tabindex: "-1" })
    const head = element("header", "pkt-sheet-head")
    this.prev = element("button", "pkt-sheet-step", { type: "button", "aria-label": this.strings.prev || "Previous day", title: this.strings.prev || "" })
    this.prev.textContent = "‹"
    this.prev.addEventListener("click", () => this.onStep && this.onStep(-1))
    this.next = element("button", "pkt-sheet-step", { type: "button", "aria-label": this.strings.next || "Next day", title: this.strings.next || "" })
    this.next.textContent = "›"
    this.next.addEventListener("click", () => this.onStep && this.onStep(1))
    const titles = element("div", "pkt-sheet-titles")
    this.title = element("h2", "pkt-sheet-title", { id: `${id}-title` })
    this.count = element("p", "pkt-sheet-count")
    titles.append(this.title, this.count)
    this.close = element("button", "pkt-sheet-close", { type: "button", "aria-label": this.strings.close || "Close", title: this.strings.close || "" })
    this.close.textContent = "✕"
    this.close.addEventListener("click", () => this.onClose && this.onClose())
    head.append(this.prev, titles, this.next, this.close)

    this.grid = element("div", "pkt-sheet-grid")
    this.grid.addEventListener("click", (event) => {
      const tile = event.target.closest?.(".pkt-sheet-tile")
      if (!tile || tile.dataset.id === undefined) return
      this.onOpen && this.onOpen(tile.dataset.id, Number(tile.dataset.global))
    })
    this.root.append(head, this.grid)
  }

  /** Open on `day` (or turn to it), with the days around it for ‹ ›. */
  show(day, { prev = null, next = null } = {}) {
    this.build()
    const turning = this.isOpen
    if (!turning) this.returnFocus = document.activeElement
    this.day = day
    this.title.textContent = dayLabel(day.date, this.lang)
    this.count.textContent = countLabel(day.count, this.strings)
    this.prev.disabled = !prev
    this.next.disabled = !next
    this.tiles.clear()
    this.grid.replaceChildren()
    // A place for every photo at once, so the sheet has its height before they arrive.
    for (let i = 0; i < day.count; i++) {
      const tile = element("button", "pkt-sheet-tile", { type: "button" })
      tile.disabled = true
      this.grid.append(tile)
    }
    this.grid.scrollTop = 0
    if (!turning) {
      document.body.append(this.backdrop, this.root)
      document.addEventListener("keydown", this.onKey)
      requestAnimationFrame(() => this.root && this.root.classList.add("pkt-sheet-open"))
      this.backdrop.classList.add("pkt-sheet-open")
      this.root.focus({ preventScroll: true })
    }
  }

  /** The day's items, in order (some may still be missing: those places wait). */
  fill(items) {
    if (!this.isOpen) return
    const density = Math.min(window.devicePixelRatio || 1, 3)
    const tiles = this.grid.children
    items.forEach((item, i) => {
      const tile = tiles[i]
      if (!item || !tile || tile.dataset.id === item.id) return
      tile.replaceChildren()
      tile.disabled = item.pending === true
      tile.dataset.id = item.id
      tile.dataset.global = String(this.day.start + i)
      tile.dataset.kind = item.kind || "image"
      tile.setAttribute("aria-label", item.name || "")
      const img = element("img", "", { alt: "", draggable: "false", decoding: "async" })
      const src = pickSource(item, TILE, TILE, { crop: true }, density)
      if (src) img.src = src
      tile.append(img)
      if (item.kind === "video") tile.append(Object.assign(element("span", "pkt-sheet-badge"), { textContent: duration(item.duration) }))
      if (item.stack && item.stack.count >= 2) tile.append(Object.assign(element("span", "pkt-sheet-stack"), { textContent: String(item.stack.count) }))
      this.tiles.set(item.id, tile)
    })
  }

  imgOf(id) {
    const tile = this.tiles.get(id)
    return tile ? tile.querySelector("img") : null
  }

  key(event) {
    if (!this.isOpen || event.defaultPrevented) return
    // The swipe viewer over the sheet has its own keys.
    if (document.querySelector(".pswp--open, .pk-snap[data-open]")) return
    if (event.key === "Escape") {
      event.preventDefault()
      this.onClose && this.onClose()
    } else if ((event.key === "ArrowLeft" || event.key === "ArrowRight") && !event.target.closest?.("input, textarea, select")) {
      event.preventDefault()
      this.onStep && this.onStep(event.key === "ArrowLeft" ? -1 : 1)
    }
  }

  hide() {
    if (!this.isOpen) return
    this.day = null
    this.tiles.clear()
    document.removeEventListener("keydown", this.onKey)
    this.root.classList.remove("pkt-sheet-open")
    this.backdrop.classList.remove("pkt-sheet-open")
    this.root.remove()
    this.backdrop.remove()
    const back = this.returnFocus
    this.returnFocus = null
    if (back && back.isConnected && back.focus) back.focus({ preventScroll: true })
  }

  destroy() {
    this.hide()
    this.root = null
  }
}
