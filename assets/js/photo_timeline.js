import {
  squareSectionHeight,
  buildOffsets,
  totalHeight,
  visibleSections,
  anchorAt
} from "./geometry.js"

// Defaults; the server may override them through the index payload.
const DEFAULTS = { cell: 160, gap: 4, header: 40 }

/**
 * The timeline hook.
 *
 * Division of labour: LiveView owns permissions, window transport and
 * PubSub; this hook owns geometry, tile recycling and jump-to-month.
 * Nothing here knows about Elixir, Ecto or PhoenixKit — the contract is
 * two JSON shapes, `timeline:index` and `timeline:window`.
 *
 * The hook name must stay globally unique. The :phoenix_kit_js_sources
 * compiler folds every bundle's global into window.PhoenixKitHooks with
 * Object.assign, which is last-write-wins on hook names and cannot see
 * inside a prebuilt bundle. `PhotoTimeline`, never `Grid`.
 */
export const PhotoTimeline = {
  mounted() {
    this.columns = Math.max(1, parseInt(this.el.dataset.columns || "5", 10) || 5)
    this.metrics = { ...DEFAULTS }
    this.sections = []
    this.offsets = [0]
    this.windows = new Map()
    this.pool = new Map()
    this.library = null
    this.revision = null
    this.needed = new Set()

    this.spacer = this.el.querySelector(".phoenix-kit-photo-timeline__spacer")
    this.layer = this.el.querySelector(".phoenix-kit-photo-timeline__layer")

    this.onScroll = throttleToFrame(() => this.handleScroll())
    this.el.addEventListener("scroll", this.onScroll, { passive: true })

    this.onResize = debounce(() => this.handleResize(), 120)
    window.addEventListener("resize", this.onResize)
    this.resizeObserver = new ResizeObserver(this.onResize)
    this.resizeObserver.observe(this.el)

    const prefix = `timeline:${this.el.dataset.timelineId}`
    this.handleEvent(`${prefix}:index`, (payload) => this.setIndex(payload))
    this.handleEvent(`${prefix}:window`, (payload) => this.setWindow(payload))
    this.handleEvent(`${prefix}:jump`, ({ id }) => this.jumpTo(id))
    this.send("timeline:ready", {})
  },

  send(event, payload) {
    this.pushEventTo(Number(this.el.dataset.target), event, payload)
  },

  reconnected() {
    this.send("timeline:ready", {})
  },

  destroyed() {
    this.el.removeEventListener("scroll", this.onScroll)
    window.removeEventListener("resize", this.onResize)
    this.resizeObserver.disconnect()
    this.onResize.cancel()
    this.onScroll.cancel()
    this.pool.clear()
  },

  setIndex(payload) {
    const libraryChanged = payload.library !== this.library
    const anchor = libraryChanged ? null : this.captureAnchor()
    this.library = payload.library
    if (payload.revision === this.revision && !libraryChanged) return
    this.revision = payload.revision
    this.windows.clear()

    this.sections = payload.sections || []
    if (payload.metrics) this.metrics = { ...this.metrics, ...payload.metrics }
    this.relayout(anchor)

    if (libraryChanged) {
      const height = totalHeight(this.offsets)
      this.el.scrollTop = Math.max(0, height - this.el.clientHeight)
    }

    this.handleScroll()
  },

  measure(section) {
    const { cell, gap, header } = this.metrics
    return squareSectionHeight({
      count: section.count,
      columns: this.columns,
      cell,
      gap,
      header
    })
  },

  /**
   * Rebuild every offset and restore position by anchor item.
   *
   * Not by scrollTop delta: on a resize every section above the viewport
   * changed height too, so a per-section correction leaves the user
   * somewhere else in their history.
   */
  captureAnchor() {
    const anchor = anchorAt(this.offsets, this.el.scrollTop)
    if (!anchor) return null
    return {
      id: this.sections[anchor.index]?.id,
      index: anchor.index,
      headerOffset: Math.min(anchor.delta, this.metrics.header),
      row: Math.max(0, anchor.delta - this.metrics.header) / (this.metrics.cell + this.metrics.gap)
    }
  },

  relayout(anchor = this.captureAnchor()) {
    if (this.el.clientWidth > 0) {
      this.metrics.cell = Math.max(1, (this.el.clientWidth - (this.columns - 1) * this.metrics.gap) / this.columns)
    }
    this.offsets = buildOffsets(this.sections, (s) => this.measure(s))
    if (this.spacer) this.spacer.style.height = `${totalHeight(this.offsets)}px`
    if (anchor && this.sections.length) {
      const found = this.sections.findIndex(s => s.id === anchor.id)
      const index = found >= 0 ? found : Math.min(anchor.index, this.sections.length - 1)
      const delta = found >= 0 ? anchor.headerOffset + anchor.row * (this.metrics.cell + this.metrics.gap) : 0
      this.el.scrollTop = this.offsets[index] + delta
    }
  },

  handleResize() {
    this.relayout()
    this.handleScroll()
  },

  handleScroll() {
    const indices = visibleSections(this.offsets, this.el.scrollTop, this.el.clientHeight)
    this.needed = new Set()
    for (const i of indices) this.ensureVisibleDays(this.sections[i])
    for (const day of this.windows.keys()) {
      if (!this.needed.has(day)) this.windows.delete(day)
    }
    this.materialize(indices)
  },

  /**
   * Request the days of a section that intersect the viewport, plus the
   * neighbouring day, so a jump does not land on an empty month.
   *
   * Windows are days, never months.
   */
  ensureVisibleDays(section) {
    if (!section) return
    const days = section.days_list || []
    const needed = new Set()

    const { first, last } = this.visibleItemRange(section)
    for (let index = first; index <= last; index++) {
      const dayIndex = dayIndexFor(days, index)
      if (dayIndex < 0) continue
      needed.add(dayIndex)
      if (dayIndex > 0) needed.add(dayIndex - 1)
      if (dayIndex + 1 < days.length) needed.add(dayIndex + 1)
    }

    for (const dayIndex of needed) this.requestDay(days[dayIndex].id)
  },

  requestDay(day) {
    if (!day) return
    this.needed.add(day)
    if (this.windows.has(day)) return
    this.windows.set(day, null)
    this.send("timeline:need_window", { window: day, revision: this.revision })
  },

  setWindow({ section, items, revision }) {
    if (revision !== this.revision || !this.windows.has(section)) return
    this.windows.set(section, items || [])
    this.handleScroll()
  },

  /** Jump to a section id, e.g. "2018-07". */
  jumpTo(sectionId) {
    const index = this.sections.findIndex((s) => s.id === sectionId)
    if (index >= 0) {
      this.el.scrollTop = this.offsets[index]
      this.handleScroll()
    }
  },

  visibleItemRange(section) {
    const sectionIndex = this.sections.indexOf(section)
    if (sectionIndex < 0 || !section || section.count <= 0) return { first: 0, last: -1 }

    const { cell, gap, header } = this.metrics
    const stride = cell + gap
    const contentTop = this.offsets[sectionIndex] + header
    const viewTop = this.el.scrollTop
    const viewBottom = viewTop + this.el.clientHeight
    const firstRow = Math.max(0, Math.floor((viewTop - contentTop) / stride) - 1)
    const lastRow = Math.ceil((viewBottom - contentTop) / stride) + 1
    const lastIndex = Math.max(0, section.count - 1)
    if (lastRow < 0 || firstRow * this.columns > lastIndex) return { first: 0, last: -1 }

    return {
      first: Math.min(lastIndex, firstRow * this.columns),
      last: Math.min(lastIndex, (lastRow + 1) * this.columns - 1)
    }
  },

  materialize(sectionIndices) {
    if (!this.layer) return

    const wanted = []
    const keep = new Set()
    for (const sectionIndex of sectionIndices) {
      const section = this.sections[sectionIndex]
      if (!section) continue
      keep.add(`header:${section.id}`)
      this.placeHeader(section, sectionIndex)
      const { first, last } = this.visibleItemRange(section)
      for (let index = first; index <= last; index++) {
        const item = itemAt(section, index, this.windows)
        if (!item) continue
        keep.add(item.id)
        wanted.push({ item, ...this.tilePosition(sectionIndex, index) })
      }
    }

    for (const [id, node] of this.pool) {
      if (!keep.has(id)) {
        node.remove()
        this.pool.delete(id)
      }
    }

    for (const entry of wanted) this.placeTile(entry)
  },

  placeHeader(section, sectionIndex) {
    const id = `header:${section.id}`
    let node = this.pool.get(id)
    if (!node) {
      node = document.createElement("div")
      node.className = "pointer-events-none px-1 text-sm font-semibold"
      this.layer.appendChild(node)
      this.pool.set(id, node)
    }
    node.textContent = section.label || section.id
    node.style.position = "absolute"
    node.style.left = "0"
    node.style.top = `${this.offsets[sectionIndex]}px`
    node.style.height = `${this.metrics.header}px`
    node.style.lineHeight = `${this.metrics.header}px`
  },

  tilePosition(sectionIndex, index) {
    const { cell, gap, header } = this.metrics
    const col = index % this.columns
    const row = Math.floor(index / this.columns)
    return {
      x: col * (cell + gap),
      y: this.offsets[sectionIndex] + header + row * (cell + gap),
      size: cell
    }
  },

  placeTile({ item, x, y, size }) {
    let node = this.pool.get(item.id)
    if (!node) {
      node = document.createElement("button")
      node.type = "button"
      node.dataset.fileId = item.id
      node.setAttribute("aria-label", item.kind === "video" ? "Open video" : "Open photo")
      node.className = "pointer-events-auto overflow-hidden bg-base-200 p-0"
      node.addEventListener("click", () => {
        this.send("timeline:open", { id: item.id })
      })
      const img = document.createElement("img")
      img.alt = ""
      img.loading = "lazy"
      img.decoding = "async"
      img.draggable = false
      img.style.width = "100%"
      img.style.height = "100%"
      img.style.objectFit = "cover"
      node.appendChild(img)
      this.layer.appendChild(node)
      this.pool.set(item.id, node)
    }

    node.style.position = "absolute"
    node.style.left = `${x}px`
    node.style.top = `${y}px`
    node.style.width = `${size}px`
    node.style.height = `${size}px`

    const img = node.querySelector("img")
    const src = item.thumb || item.preview
    if (img && src && img.dataset.src !== src) {
      img.dataset.src = src
      img.src = src
    } else if (img && !src) {
      img.removeAttribute("src")
      delete img.dataset.src
    }
  }
}

function dayIndexFor(days, itemIndex) {
  let cursor = 0
  for (let i = 0; i < days.length; i++) {
    const count = days[i].count || 0
    if (itemIndex < cursor + count) return i
    cursor += count
  }
  return -1
}

function itemAt(section, itemIndex, windows) {
  const days = section.days_list || []
  let cursor = 0
  for (const day of days) {
    const count = day.count || 0
    if (itemIndex < cursor + count) {
      const items = windows.get(day.id)
      if (!items) return null
      return items[itemIndex - cursor] || null
    }
    cursor += count
  }
  return null
}

function throttleToFrame(fn) {
  let scheduled = null
  const callback = () => {
    if (scheduled !== null) return
    scheduled = requestAnimationFrame(() => {
      scheduled = null
      fn()
    })
  }
  callback.cancel = () => {
    if (scheduled !== null) cancelAnimationFrame(scheduled)
    scheduled = null
  }
  return callback
}

function debounce(fn, ms) {
  let timer = null
  const callback = () => {
    clearTimeout(timer)
    timer = setTimeout(fn, ms)
  }
  callback.cancel = () => clearTimeout(timer)
  return callback
}
