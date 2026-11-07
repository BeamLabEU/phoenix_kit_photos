// Choosing many photos at once. The tiles are virtual, so what is chosen is a set of file ids
// held here, not a state of the DOM, and a tile that scrolls back in comes back chosen. A range
// that runs through months nobody has scrolled to is resolved by the server, which knows the
// order of the whole library (`timeline:range`).
//
// How a person gets there:
//
//   * the circle on a tile, or Ctrl/Cmd + click, starts a selection; after that a click toggles
//   * Shift + click takes everything between the last tile and this one, across months
//   * dragging with the mouse draws a box, the page scrolling at the top and bottom edges
//   * on a touch screen, hold a tile, then slide over others without letting go
//   * the circle on a month's header takes the month
//   * Ctrl/Cmd + A takes everything, Escape lets go, Delete asks to trash
//
// The bar along the bottom is the component's markup; this file only shows it and counts.

const HOLD_MS = 380
const DRAG_PX = 6
const HOLD_SLOP_PX = 10
const EDGE_PX = 64
const EDGE_SPEED = 18
// Photos taken within this of each other are one moment ("this moment").
const MOMENT_GAP_MS = 4 * 60 * 1000

export const selection = {
  selected: null,
  selectAnchor: null,
  selectMode: false,

  selectable() {
    return this.el.dataset.selectable === "true"
  },

  /** Whether a plain click toggles instead of opening. */
  selecting() {
    return this.selectMode || (this.selected?.size || 0) > 0
  },

  isSelected(id) {
    return Boolean(this.selected?.has(id))
  },

  /** The number and the id of what is chosen, for a request. */
  selectedIds() {
    return [...(this.selected || [])]
  },

  // --- changing what is chosen ---------------------------------------------

  toggleSelected(id, global) {
    this.selected = this.selected || new Set()
    if (this.selected.has(id)) this.selected.delete(id)
    else this.selected.add(id)
    this.selectAnchor = global
    this.selectionChanged()
  },

  clearSelection() {
    this.selected?.clear()
    this.selectMode = false
    this.selectAnchor = null
    this.selectionChanged()
  },

  addSelected(ids) {
    this.selected = this.selected || new Set()
    for (const id of ids) this.selected.add(id)
    this.selectionChanged()
  },

  removeSelected(ids) {
    for (const id of ids) this.selected?.delete(id)
    this.selectionChanged()
  },

  /** The ids of positions `from` to `to`, or null when some have not been fetched. */
  loadedIds(from, to) {
    const ids = []
    for (let global = from; global <= to; global++) {
      const id = this.itemAtGlobal(global)?.id
      if (!id) return null
      ids.push(id)
    }
    return ids
  },

  itemAtGlobal(global) {
    const found = this.sectionOf(global)
    if (found < 0) return null
    let cursor = global - this.sectionStarts[found]
    for (const day of this.sections[found].days_list || []) {
      const count = day.count || 0
      if (cursor < count) return this.windows.get(day.id)?.[cursor] || null
      cursor -= count
    }
    return null
  },

  sectionOf(global) {
    let found = -1
    const starts = this.sectionStarts || []
    for (let i = 0; i < starts.length && starts[i] <= global; i++) found = i
    return found
  },

  /**
   * Take a run of positions. What is on hand is taken at once; the rest comes from the server.
   * `mode` is add, remove, or toggle: remove when the whole run is already chosen.
   */
  selectRange(from, to, mode = "add") {
    const [first, last] = from <= to ? [from, to] : [to, from]
    const ids = this.loadedIds(first, last)
    if (ids) this.applyRange({ ids, mode })
    else this.send("timeline:range", { from: first, to: last, mode, revision: this.revision })
  },

  applyRange({ ids, mode, capped, revision }) {
    if (revision !== undefined && revision !== this.revision) return
    const remove = mode === "remove" || (mode === "toggle" && ids.every(id => this.selected?.has(id)))
    if (remove) this.removeSelected(ids)
    else this.addSelected(ids)
    this.noteCapped(capped)
  },

  /** The server took as many as a selection may hold; say so where the count is. */
  noteCapped(capped) {
    const note = this.root()?.querySelector("[data-selection-capped]")
    if (note) note.hidden = !capped
  },

  /** Everything between the last tile touched and this one. */
  selectTo(global) {
    this.selectRange(this.selectAnchor, global)
    this.selectAnchor = global
  },

  /** The whole of a month. */
  selectSection(index) {
    const section = this.sections[index]
    if (!section || section.count <= 0) return
    const first = this.sectionStarts[index]
    this.selectRange(first, first + section.count - 1, "toggle")
  },

  selectAll() {
    const total = (this.sections || []).reduce((sum, section) => sum + section.count, 0)
    if (total > 0) this.selectRange(0, total - 1)
  },

  /** The day of the last tile touched. */
  selectDay() {
    const global = this.selectAnchor
    const found = global === null ? -1 : this.sectionOf(global)
    if (found < 0) return
    let start = this.sectionStarts[found]
    const days = this.sections[found].days_list || []
    for (let i = 0; i < days.length; i++) {
      // A big day comes in slices, named `<day>:<offset>`, which are still one day.
      const day = days[i].id.split(":")[0]
      let end = start
      let j = i
      for (; j < days.length && days[j].id.split(":")[0] === day; j++) end += days[j].count || 0
      if (global < end) {
        this.selectRange(start, end - 1)
        return
      }
      start = end
      i = j - 1
    }
  },

  /** The photos taken around the last tile touched: a burst, a walk down one street. */
  selectMoment() {
    const global = this.selectAnchor
    if (global === null) return
    const time = at => {
      const stamp = this.itemAtGlobal(at)?.taken_at
      return stamp ? Date.parse(stamp) : NaN
    }
    let first = global
    let last = global
    while (first > 0 && time(first) - time(first - 1) <= MOMENT_GAP_MS) first--
    while (time(last + 1) - time(last) <= MOMENT_GAP_MS) last++
    this.selectRange(first, last)
  },

  /** Ask the server for one kind of file in the whole library: `video` or `image`. */
  selectKind(kind) {
    this.send("timeline:range", { kind, mode: "add", revision: this.revision })
  },

  // --- showing it -----------------------------------------------------------

  root() {
    return this.el.closest?.(".phoenix-kit-photo-timeline") || null
  },

  selectionChanged() {
    const count = this.selected?.size || 0
    if (this.el.dataset) this.el.dataset.selecting = this.selecting() ? "true" : "false"
    for (const [key, node] of this.pool) {
      if (!key.startsWith("header:")) node.toggleAttribute?.("data-selected", this.isSelected(key))
    }
    const root = this.root()
    if (!root) return
    const bar = root.querySelector("[data-selection-bar]")
    if (bar) bar.hidden = !this.selecting()
    const counter = root.querySelector("[data-selection-count]")
    if (counter) counter.textContent = count.toLocaleString(document.documentElement.lang || undefined)
    if (count === 0) this.noteCapped(false)
    for (const button of root.querySelectorAll("[data-bulk]")) button.disabled = count === 0
  },

  /** A tile was clicked. */
  tileClick(event, node, id) {
    // The click that ends a drag or a hold is not a click.
    if (Date.now() - (this.dragEndedAt || 0) < 60) return
    const global = Number(node.dataset.global)
    if (!this.selectable()) return this.openTile(id, global)

    if (event.shiftKey && this.selectAnchor !== null) {
      this.selectTo(global)
    } else if (event.target.closest?.(".pkt-check") || event.metaKey || event.ctrlKey || this.selecting()) {
      this.toggleSelected(id, global)
    } else {
      this.openTile(id, global)
    }
  },

  // --- mouse: drawing a box ---------------------------------------------------

  /** The pointer on the page, on the layer: the box lives there, and so scrolls with the tiles. */
  layerPoint(event) {
    const box = this.el.getBoundingClientRect()
    return { x: event.clientX - box.left, y: event.clientY - box.top + this.el.scrollTop, clientY: event.clientY }
  },

  pointerDown(event) {
    if (!this.selectable() || this.pager || event.button !== 0) return
    const tile = event.target.closest?.(".pkt-tile")
    if (event.pointerType === "mouse") {
      // The scrollbar is part of the element, but not of the page.
      const box = this.el.getBoundingClientRect()
      if (event.clientX >= box.left + this.el.clientWidth) return
      if (event.target.closest?.("[data-section-select]")) return
      this.drag = { start: this.layerPoint(event), keep: event.shiftKey || event.metaKey || event.ctrlKey || this.selecting() }
      window.addEventListener("pointermove", this.onDragMove)
      window.addEventListener("pointerup", this.onDragEnd)
      window.addEventListener("pointercancel", this.onDragEnd)
    } else if (tile) {
      clearTimeout(this.holdTimer)
      this.hold = { x: event.clientX, y: event.clientY }
      this.holdTimer = setTimeout(() => this.beginPaint(tile), HOLD_MS)
    }
  },

  dragMove(event) {
    const drag = this.drag
    if (!drag) return
    drag.last = this.layerPoint(event)
    if (!drag.box) {
      if (Math.hypot(drag.last.x - drag.start.x, drag.last.y - drag.start.y) < DRAG_PX) return
      drag.base = new Set(drag.keep ? this.selected || [] : [])
      drag.box = document.createElement("div")
      drag.box.className = "pkt-marquee"
      this.layer.appendChild(drag.box)
      this.el.dataset.dragging = "true"
    }
    this.drawBox()
    this.edgeScroll(event.clientY)
  },

  /** Draw the box, and choose what it touches. Runs again when windows arrive under it. */
  drawBox() {
    const drag = this.drag
    if (!drag?.box) return
    const left = Math.min(drag.start.x, drag.last.x)
    const top = Math.min(drag.start.y, drag.last.y)
    const right = Math.max(drag.start.x, drag.last.x)
    const bottom = Math.max(drag.start.y, drag.last.y)
    Object.assign(drag.box.style, {
      left: `${left}px`, top: `${top}px`, width: `${right - left}px`, height: `${bottom - top}px`
    })
    this.selected = new Set(drag.base)
    for (const id of this.idsInBox(left, top, right, bottom)) this.selected.add(id)
    this.selectionChanged()
  },

  idsInBox(left, top, right, bottom) {
    const ids = []
    for (let index = 0; index < this.sections.length; index++) {
      const start = this.offsets[index]
      if (this.offsets[index + 1] < top) continue
      if (start > bottom) break
      const section = this.sections[index]
      const layout = this.layoutOf(section)
      const { first, last } = layout.range(top - start, bottom - start)
      for (let item = first; item <= last; item++) {
        const r = layout.rect(item)
        const y = start + r.y
        if (r.x > right || r.x + r.w < left || y > bottom || y + r.h < top) continue
        const found = this.itemAtGlobal(this.sectionStarts[index] + item)
        if (found) ids.push(found.id)
      }
    }
    return ids
  },

  /** Near the top or bottom of the page the box, or the finger, takes the page along. */
  edgeScroll(clientY) {
    const box = this.el.getBoundingClientRect()
    const top = box.top + this.inset
    const speed = clientY < top + EDGE_PX
      ? -EDGE_SPEED * Math.min(1, (top + EDGE_PX - clientY) / EDGE_PX)
      : clientY > box.bottom - EDGE_PX
        ? EDGE_SPEED * Math.min(1, (clientY - box.bottom + EDGE_PX) / EDGE_PX)
        : 0
    this.edgeSpeed = speed
    if (speed && !this.edgeFrame) this.edgeFrame = requestAnimationFrame(() => this.edgeStep())
  },

  edgeStep() {
    this.edgeFrame = null
    if (!this.edgeSpeed || !(this.drag?.box || this.paint)) return
    this.el.scrollTop += this.edgeSpeed
    if (this.drag?.last) {
      this.drag.last = { ...this.drag.last, y: this.drag.last.y + this.edgeSpeed }
      this.drawBox()
    }
    this.edgeFrame = requestAnimationFrame(() => this.edgeStep())
  },

  dragEnd() {
    const drag = this.drag
    this.drag = null
    this.edgeSpeed = 0
    window.removeEventListener("pointermove", this.onDragMove)
    window.removeEventListener("pointerup", this.onDragEnd)
    window.removeEventListener("pointercancel", this.onDragEnd)
    if (!drag?.box) return
    drag.box.remove()
    delete this.el.dataset.dragging
    this.dragEndedAt = Date.now()
  },

  // --- touch: hold, then slide ---------------------------------------------------

  beginPaint(tile) {
    this.hold = null
    const global = Number(tile.dataset.global)
    const id = tile.dataset.fileId
    this.selected = this.selected || new Set()
    const removing = this.selected.has(id)
    this.paint = { from: global, to: global, base: new Set(this.selected), removing }
    this.selectAnchor = global
    this.paintTo(global)
    navigator.vibrate?.(12)
  },

  paintTo(global) {
    const paint = this.paint
    paint.to = global
    const [from, to] = paint.from <= global ? [paint.from, global] : [global, paint.from]
    this.selected = new Set(paint.base)
    for (let at = from; at <= to; at++) {
      const id = this.itemAtGlobal(at)?.id
      if (!id) continue
      if (paint.removing) this.selected.delete(id)
      else this.selected.add(id)
    }
    this.selectionChanged()
  },

  /** Claims the touch for the selection: the page must not scroll while a finger paints. */
  selectionTouchMove(event) {
    if (this.hold) {
      const touch = event.touches[0]
      if (touch && Math.hypot(touch.clientX - this.hold.x, touch.clientY - this.hold.y) > HOLD_SLOP_PX) this.cancelHold()
    }
    if (!this.paint) return
    event.preventDefault()
    const touch = event.touches[0]
    if (!touch) return
    const tile = document.elementFromPoint(touch.clientX, touch.clientY)?.closest?.(".pkt-tile")
    if (tile) this.paintTo(Number(tile.dataset.global))
    this.edgeScroll(touch.clientY)
  },

  cancelHold() {
    clearTimeout(this.holdTimer)
    this.hold = null
  },

  selectionTouchEnd() {
    this.cancelHold()
    if (!this.paint) return
    this.paint = null
    this.edgeSpeed = 0
    this.dragEndedAt = Date.now()
  },

  // --- keys, the bar, the headers -----------------------------------------------

  selectionKey(event) {
    if (!this.selectable() || this.pager) return
    const target = event.target
    if (target && (/^(input|select|textarea)$/i.test(target.tagName || "") || target.isContentEditable)) return

    if (event.key === "Escape" && this.selecting()) {
      this.clearSelection()
    } else if ((event.metaKey || event.ctrlKey) && event.key.toLowerCase() === "a") {
      event.preventDefault()
      this.selectAll()
    } else if ((event.key === "Delete" || event.key === "Backspace") && (this.selected?.size || 0) > 0) {
      event.preventDefault()
      this.bulk("trash")
    }
  },

  /** Ask for an action on what is chosen. The server checks each file and answers with a plan. */
  bulk(action) {
    const ids = this.selectedIds()
    if (ids.length === 0) return
    if (action === "download") this.download(ids)
    else this.send("timeline:bulk", { action, ids })
  },

  /**
   * A form posted to the host's download address: the answer is an attachment, so the page stays,
   * and thousands of ids fit in a body where they would not fit in a link.
   */
  download(ids) {
    const root = this.root()
    const action = root?.dataset.downloadPath
    if (!action) return
    const form = document.createElement("form")
    form.method = "post"
    form.action = action
    form.hidden = true
    const field = (name, value) => {
      const input = document.createElement("input")
      input.type = "hidden"
      input.name = name
      input.value = value
      form.appendChild(input)
    }
    field("_csrf_token", document.querySelector("meta[name='csrf-token']")?.content || "")
    field("ids", ids.join(","))
    document.body.appendChild(form)
    form.submit()
    form.remove()
  },

  /** The addresses of what is chosen, as a person will paste them: with the site in front. */
  showLinks({ paths }) {
    const box = this.root()?.querySelector("[data-links]")
    if (box) box.value = (paths || []).map(path => window.location.origin + path).join("\n")
  },

  /** Every click on the bar, and on a month's circle. */
  selectionClick(event) {
    const target = event.target
    const action = target.closest?.("[data-bulk]")
    if (action) return this.bulk(action.dataset.bulk)
    const copy = target.closest?.("[data-copy-links]")
    if (copy) {
      const box = this.root()?.querySelector("[data-links]")
      if (!box) return
      box.select()
      navigator.clipboard?.writeText(box.value)
      copy.textContent = copy.dataset.done || copy.textContent
      return
    }
    const pick = target.closest?.("[data-select]")
    if (pick) {
      const choices = {
        all: () => this.selectAll(),
        day: () => this.selectDay(),
        moment: () => this.selectMoment(),
        videos: () => this.selectKind("video"),
        photos: () => this.selectKind("image"),
        none: () => this.clearSelection()
      }
      choices[pick.dataset.select]?.()
      target.closest?.("details")?.removeAttribute("open")
      return
    }
    if (target.closest?.("[data-select-start]")) {
      this.selectMode = !this.selecting()
      if (!this.selectMode) this.clearSelection()
      else this.selectionChanged()
    }
  },

  /** The server finished, or changed what may stay chosen. */
  applySelection({ clear, remove }) {
    if (clear) this.clearSelection()
    else if (remove) this.removeSelected(remove)
  },

  bindSelection() {
    if (!this.selectable()) return
    this.selected = this.selected || new Set()
    this.onDragMove = (event) => this.dragMove(event)
    this.onDragEnd = () => this.dragEnd()
    this.onSelectDown = (event) => this.pointerDown(event)
    this.onSelectKey = (event) => this.selectionKey(event)
    this.onSelectClick = (event) => this.selectionClick(event)
    this.onSelectTouchMove = (event) => this.selectionTouchMove(event)
    this.onSelectTouchEnd = () => this.selectionTouchEnd()
    this.onSelectContext = (event) => {
      if (this.paint || this.hold) event.preventDefault()
    }
    this.el.addEventListener("pointerdown", this.onSelectDown)
    this.el.addEventListener("touchmove", this.onSelectTouchMove, { passive: false })
    this.el.addEventListener("touchend", this.onSelectTouchEnd)
    this.el.addEventListener("touchcancel", this.onSelectTouchEnd)
    this.el.addEventListener("contextmenu", this.onSelectContext)
    window.addEventListener("keydown", this.onSelectKey)
    this.root()?.addEventListener("click", this.onSelectClick)
    this.selectionChanged()
  },

  unbindSelection() {
    if (!this.onSelectDown) return
    this.dragEnd()
    this.cancelHold()
    this.el.removeEventListener("pointerdown", this.onSelectDown)
    this.el.removeEventListener("touchmove", this.onSelectTouchMove)
    this.el.removeEventListener("touchend", this.onSelectTouchEnd)
    this.el.removeEventListener("touchcancel", this.onSelectTouchEnd)
    this.el.removeEventListener("contextmenu", this.onSelectContext)
    window.removeEventListener("keydown", this.onSelectKey)
    this.root()?.removeEventListener("click", this.onSelectClick)
  }
}
