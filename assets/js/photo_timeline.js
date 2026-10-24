import {
  squareSectionHeight,
  buildOffsets,
  totalHeight,
  visibleSections,
  sectionAtOffset,
  anchorAt
} from "./geometry.js"
import { SlideStore, wantWidth } from "./slides.js"
import { engineFor, loadEngine } from "./viewer/engine.js"
import "./viewer/engines.js"
import { VideoController } from "./viewer/video.js"

// Defaults; the server may override them through the index payload.
const DEFAULTS = { cell: 160, gap: 4, header: 40 }

// Zoom: the smallest tile a person can pinch down to, and where the choice is remembered.
const MIN_CELL = 56
const ZOOM_KEY = "phoenix_kit_photos:cell"

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
  // Height of the header the grid scrolls under (see `readInset`).
  inset: 0,
  // A pinch in progress, and the tile size a pinch chose (see "zoom" below).
  pinch: null,
  zoomCell: null,

  mounted() {
    this.columns = Math.max(1, parseInt(this.el.dataset.columns || "5", 10) || 5)
    // What the host asked for; `columns` is what is on screen, which zooming changes.
    this.baseColumns = this.columns
    // With a target tile size the number of columns follows the width of the screen.
    this.targetCell = parseInt(this.el.dataset.cell || "0", 10) || 0
    this.fill = this.el.dataset.fill === "true"
    this.metrics = { ...DEFAULTS }
    const gap = parseInt(this.el.dataset.gap || "", 10)
    if (Number.isFinite(gap) && gap >= 0) this.metrics.gap = gap
    this.inset = 0
    // A tile size the person chose by pinching (or + and -); null follows the host's `cell`.
    this.zoomCell = this.storedZoom()
    this.pinch = null
    this.current = this.el.closest(".phoenix-kit-photo-timeline")?.querySelector("[data-current-section]")
    this.sections = []
    this.offsets = [0]
    this.windows = new Map()
    // Files this library has shown us, and which of them just arrived (see `noteArrivals`).
    this.known = new Set()
    this.fresh = new Set()
    // Windows asked for again because storage changed, answered by `setWindow`.
    this.refreshing = new Set()
    this.pool = new Map()
    this.library = null
    this.revision = null
    this.needed = new Set()
    this.slides = new SlideStore([])
    this.sectionStarts = []
    this.pager = null
    this.pendingOpen = null

    this.spacer = this.el.querySelector(".phoenix-kit-photo-timeline__spacer")
    this.layer = this.el.querySelector(".phoenix-kit-photo-timeline__layer")

    this.onScroll = throttleToFrame(() => this.handleScroll())
    this.el.addEventListener("scroll", this.onScroll, { passive: true })

    this.bindZoom()

    this.onResize = debounce(() => this.handleResize(), 120)
    window.addEventListener("resize", this.onResize)
    this.resizeObserver = new ResizeObserver(this.onResize)
    this.resizeObserver.observe(this.el)

    const prefix = `timeline:${this.el.dataset.timelineId}`
    this.handleEvent(`${prefix}:index`, (payload) => this.setIndex(payload))
    this.handleEvent(`${prefix}:window`, (payload) => this.setWindow(payload))
    this.handleEvent(`${prefix}:jump`, ({ id }) => this.jumpTo(id))
    this.handleEvent(`${prefix}:slides`, (payload) => this.setSlides(payload))
    this.send("timeline:ready", {})
  },

  send(event, payload) {
    this.pushEventTo(Number(this.el.dataset.target), event, payload)
  },

  reconnected() {
    this.send("timeline:ready", {})
  },

  destroyed() {
    this.unbindZoom()
    this.el.removeEventListener("scroll", this.onScroll)
    window.removeEventListener("resize", this.onResize)
    this.resizeObserver.disconnect()
    this.onResize.cancel()
    this.onScroll.cancel()
    clearTimeout(this.openTimer)
    if (this.pager && this.pager.destroy) this.pager.destroy()
    this.pool.clear()
  },

  setIndex(payload) {
    const libraryChanged = payload.library !== this.library
    // The swipe viewer holds positions in the old index; let it finish, then catch up.
    if (!libraryChanged && this.pager) {
      this.deferred = payload
      return
    }

    // Storage changed under a library already on screen: a refresh, not a new library. The
    // tiles stay where they are while the windows are fetched again, and what is new arrives
    // with an animation.
    const refresh = !libraryChanged && this.revision !== null
    const anchor = libraryChanged ? null : this.captureAnchor()
    const atEnd = refresh && this.atEnd()
    const heightBefore = totalHeight(this.offsets)

    this.library = payload.library
    if (payload.revision === this.revision && !libraryChanged) return
    this.revision = payload.revision
    if (libraryChanged) {
      this.windows.clear()
      this.known.clear()
    }
    this.fresh.clear()
    this.refreshing.clear()

    this.sections = payload.sections || []
    this.resetSlides()
    if (payload.metrics) {
      const { gap, ...rest } = payload.metrics
      this.metrics = { ...this.metrics, ...rest }
      if (this.el.dataset.gap === undefined && gap !== undefined) this.metrics.gap = gap
    }
    this.relayout(anchor)

    if (libraryChanged) {
      const height = totalHeight(this.offsets)
      this.el.scrollTop = Math.max(0, height - this.el.clientHeight)
    } else if (atEnd && totalHeight(this.offsets) > heightBefore) {
      this.followEnd()
    }

    if (refresh) this.revalidate()
    this.markNew = refresh
    this.handleScroll()
    this.markNew = false
  },

  /** Whether the person is looking at the end of the library, where new photos land. */
  atEnd() {
    const height = totalHeight(this.offsets)
    return height > 0 && this.el.scrollTop + this.el.clientHeight >= height - 24
  },

  /** Keep the end in view as the library grows: glide there, or jump when motion is unwelcome. */
  followEnd() {
    const top = Math.max(0, totalHeight(this.offsets) - this.el.clientHeight)
    if (this.el.scrollTo && !reducedMotion()) this.el.scrollTo({ top, behavior: "smooth" })
    else this.el.scrollTop = top
  },

  /**
   * Ask again for every window held, without letting go of what is shown: the old tiles stay
   * until the new answer replaces them. Requests sent for the old revision would be dropped
   * on arrival, so the ones still in flight are asked again too.
   */
  revalidate() {
    for (const day of this.windows.keys()) {
      this.refreshing.add(day)
      this.send("timeline:need_window", { window: day, revision: this.revision })
    }
  },

  /** Run a deferred refresh once the viewer is closed. */
  applyDeferred() {
    if (!this.deferred) return
    const payload = this.deferred
    this.deferred = null
    this.setIndex(payload)
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
    // The top of what can be seen is below the inset: the grid scrolls under a header.
    const anchor = anchorAt(this.offsets, this.el.scrollTop + this.inset)
    if (!anchor) return null
    return {
      id: this.sections[anchor.index]?.id,
      index: anchor.index,
      headerOffset: Math.min(anchor.delta, this.metrics.header),
      // The place in the section as a count of tiles, so it survives a change of columns.
      item:
        (Math.max(0, anchor.delta - this.metrics.header) / (this.metrics.cell + this.metrics.gap)) *
        this.columns
    }
  },

  /** The height, in px, of what the grid scrolls under: `--photo-timeline-inset-top` (any CSS length). */
  readInset() {
    if (typeof getComputedStyle !== "function") return 0
    const value = getComputedStyle(this.el).getPropertyValue("--photo-timeline-inset-top").trim()
    if (!value) return 0
    // Resolve rem, calc() and env() the way the browser does: let it size a probe.
    const probe = document.createElement("div")
    probe.style.cssText = `position:absolute;visibility:hidden;pointer-events:none;height:${value}`
    this.el.appendChild(probe)
    const px = probe.offsetHeight
    probe.remove()
    return px
  },

  /**
   * Columns for this width: fixed, or as many tiles of about the target size as fit. A size
   * the person chose by zooming wins over the host's, and may go down to one column.
   */
  columnsFor(width) {
    const { gap } = this.metrics
    if (this.zoomCell && width > 0) return Math.max(1, Math.round((width + gap) / (this.zoomCell + gap)))
    if (!this.targetCell || width <= 0) return this.baseColumns ?? this.columns
    return Math.max(3, Math.round((width + gap) / (this.targetCell + gap)))
  },

  relayout(anchor = this.captureAnchor()) {
    this.inset = this.readInset()
    if (this.el.clientWidth > 0) {
      this.columns = this.columnsFor(this.el.clientWidth)
      this.metrics.cell = Math.max(1, (this.el.clientWidth - (this.columns - 1) * this.metrics.gap) / this.columns)
    }
    this.offsets = buildOffsets(this.sections, (s) => this.measure(s), this.inset)
    if (this.spacer) this.spacer.style.height = `${totalHeight(this.offsets)}px`
    if (anchor && this.sections.length) {
      const found = this.sections.findIndex(s => s.id === anchor.id)
      const index = found >= 0 ? found : Math.min(anchor.index, this.sections.length - 1)
      const row = found >= 0 ? Math.floor(anchor.item / this.columns) : 0
      const delta = found >= 0 ? anchor.headerOffset + row * (this.metrics.cell + this.metrics.gap) : 0
      this.el.scrollTop = Math.max(0, this.offsets[index] + delta - this.inset)
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
    this.showCurrent()
  },

  /** Put the label of the month at the top of the screen into the host's pill, if it has one. */
  showCurrent() {
    if (!this.current || !this.sections.length) return
    const index = sectionAtOffset(this.offsets, this.el.scrollTop + this.inset + 1)
    const label = this.sections[index]?.label || ""
    if (this.current.textContent !== label) this.current.textContent = label
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
    if (this.markNew) this.refreshing.add(day)
    this.send("timeline:need_window", { window: day, revision: this.revision })
  },

  setWindow({ section, items, revision }) {
    if (revision !== this.revision || !this.windows.has(section)) return
    const arrived = this.refreshing.delete(section)
    this.windows.set(section, items || [])
    this.noteArrivals(items || [], arrived)
    // Tiles that move because of what arrived glide to their places.
    this.gliding = arrived
    this.handleScroll()
    this.gliding = false
  },

  /**
   * Remember the files of a window. When the window was fetched again because storage changed,
   * the ones never seen before are the new photos: they will pop in.
   */
  noteArrivals(items, arrived) {
    for (const item of items) {
      if (arrived && !this.known.has(item.id)) this.fresh.add(item.id)
      this.known.add(item.id)
    }
  },

  /** Jump to a section id, e.g. "2018-07". */
  jumpTo(sectionId) {
    const index = this.sections.findIndex((s) => s.id === sectionId)
    if (index >= 0) {
      this.el.scrollTop = Math.max(0, this.offsets[index] - this.inset)
      this.handleScroll()
    }
  },

  // --- zoom: pinch, ctrl + wheel (a trackpad pinch), + and - --------------

  storedZoom() {
    try {
      const value = Number(window.localStorage.getItem(ZOOM_KEY))
      return Number.isFinite(value) && value >= MIN_CELL ? value : null
    } catch (_error) {
      return null
    }
  },

  rememberZoom() {
    try {
      if (this.zoomCell) window.localStorage.setItem(ZOOM_KEY, String(Math.round(this.zoomCell)))
      else window.localStorage.removeItem(ZOOM_KEY)
    } catch (_error) {
      // private mode and the like: the choice lasts until the page is left
    }
  },

  bindZoom() {
    this.zoomHandlers = []
    const on = (target, type, fn, options) => {
      target.addEventListener(type, fn, options)
      this.zoomHandlers.push(() => target.removeEventListener(type, fn, options))
    }

    // Two fingers. `touch-action: pan-y` on the viewport keeps the browser from zooming the
    // page itself; one finger still scrolls.
    on(this.el, "touchstart", (e) => this.touchStart(e), { passive: true })
    on(this.el, "touchmove", (e) => this.touchMove(e), { passive: false })
    on(this.el, "touchend", (e) => this.touchEnd(e), { passive: true })
    on(this.el, "touchcancel", () => this.endPinch(false), { passive: true })

    // A trackpad pinch arrives as wheel events with ctrlKey set (Chrome, Edge, Firefox).
    on(this.el, "wheel", (e) => this.wheel(e), { passive: false })

    // Safari on a Mac sends gesture events instead.
    on(this.el, "gesturestart", (e) => this.gesture(e, "start"))
    on(this.el, "gesturechange", (e) => this.gesture(e, "change"))
    on(this.el, "gestureend", (e) => this.gesture(e, "end"))

    on(window, "keydown", (e) => this.zoomKey(e))
  },

  unbindZoom() {
    for (const off of this.zoomHandlers || []) off()
    this.zoomHandlers = []
    clearTimeout(this.wheelTimer)
  },

  /** The tile under a point of the viewport (x, y from its top-left), as a section and a place in it. */
  itemAtPoint(x, y) {
    if (!this.sections.length) return null
    const index = sectionAtOffset(this.offsets, this.el.scrollTop + y)
    const section = this.sections[index]
    if (!section || section.count <= 0) return null
    const { cell, gap, header } = this.metrics
    const stride = cell + gap
    const row = Math.max(0, Math.floor((this.el.scrollTop + y - this.offsets[index] - header) / stride))
    const col = Math.min(this.columns - 1, Math.max(0, Math.floor(x / stride)))
    return { index, item: Math.min(section.count - 1, row * this.columns + col) }
  },

  /** The smallest and largest tile there can be at this width: MIN_CELL, and one column. */
  cellLimits() {
    return [MIN_CELL, Math.max(MIN_CELL, this.el.clientWidth)]
  },

  /**
   * Make tiles `cell` px (about: the columns are a whole number), keeping the photo that
   * is under (x, y) where it is on screen.
   */
  zoomTo(cell, x, y) {
    const [low, high] = this.cellLimits()
    const focus = this.itemAtPoint(x, y)
    this.zoomCell = Math.min(high, Math.max(low, cell))
    this.relayout(null)
    if (focus) {
      const row = Math.floor(focus.item / this.columns)
      const { cell: size, gap, header } = this.metrics
      const middle = this.offsets[focus.index] + header + row * (size + gap) + size / 2
      this.el.scrollTop = Math.max(0, middle - y)
    }
    this.handleScroll()
    this.rememberZoom()
  },

  /** One column more (`steps` > 0, smaller tiles) or fewer, around the middle of the screen. */
  stepZoom(steps) {
    const width = this.el.clientWidth
    if (!(width > 0)) return
    const columns = Math.max(1, this.columns + steps)
    const { gap } = this.metrics
    this.zoomTo((width - (columns - 1) * gap) / columns, width / 2, this.el.clientHeight / 2)
  },

  zoomKey(event) {
    if (this.pager || event.metaKey || event.ctrlKey || event.altKey) return
    const target = event.target
    if (target && /^(input|select|textarea)$/i.test(target.tagName || "")) return
    if (target && target.isContentEditable) return
    if (event.key === "+" || event.key === "=") this.stepZoom(-1)
    else if (event.key === "-" || event.key === "_") this.stepZoom(1)
    else if (event.key === "0") this.resetZoom()
    else return
    event.preventDefault()
  },

  /** Back to the size the host asks for. */
  resetZoom() {
    this.zoomCell = null
    this.rememberZoom()
    this.relayout()
    this.handleScroll()
  },

  /**
   * While the fingers are down the grid is only scaled on the screen (a transform: cheap and
   * smooth). When they lift, the scale becomes a tile size, and the grid is laid out again.
   */
  previewScale(scale, x, y) {
    if (!this.layer) return
    this.layer.style.transformOrigin = `${x}px ${this.el.scrollTop + y}px`
    this.layer.style.transform = scale === 1 ? "" : `scale(${scale})`
  },

  /** A scale that would take the tiles beyond what they can be is held back, with some give. */
  clampScale(scale) {
    const [low, high] = this.cellLimits()
    const cell = this.metrics.cell
    return Math.min(high / cell, Math.max(low / cell, scale))
  },

  startPinch(x, y) {
    if (!this.pinch) this.pinch = { scale: 1, x, y }
    this.pinch.x = x
    this.pinch.y = y
  },

  movePinch(scale, x, y) {
    if (!this.pinch) this.startPinch(x, y)
    this.pinch.scale = this.clampScale(scale)
    this.pinch.x = x
    this.pinch.y = y
    this.previewScale(this.pinch.scale, x, y)
  },

  endPinch(commit = true) {
    const pinch = this.pinch
    this.pinch = null
    if (!pinch) return
    this.previewScale(1, pinch.x, pinch.y)
    if (commit && Math.abs(pinch.scale - 1) > 0.02) {
      this.zoomTo(this.metrics.cell * pinch.scale, pinch.x, pinch.y)
    }
  },

  touchStart(event) {
    if (event.touches.length === 2) {
      const [a, b] = event.touches
      this.touchBase = distance(a, b)
      this.pinch = null
    } else {
      this.touchBase = null
    }
  },

  touchMove(event) {
    if (event.touches.length !== 2 || !this.touchBase) return
    event.preventDefault()
    const [a, b] = event.touches
    const box = this.el.getBoundingClientRect()
    this.movePinch(
      distance(a, b) / this.touchBase,
      (a.clientX + b.clientX) / 2 - box.left,
      (a.clientY + b.clientY) / 2 - box.top
    )
  },

  touchEnd(event) {
    if (event.touches.length < 2 && this.pinch) {
      this.touchBase = null
      this.endPinch()
    }
  },

  wheel(event) {
    if (!event.ctrlKey) return
    event.preventDefault()
    const box = this.el.getBoundingClientRect()
    const x = event.clientX - box.left
    const y = event.clientY - box.top
    const scale = (this.pinch ? this.pinch.scale : 1) * Math.exp(-event.deltaY * 0.01)
    this.movePinch(scale, x, y)
    clearTimeout(this.wheelTimer)
    this.wheelTimer = setTimeout(() => this.endPinch(), 140)
  },

  gesture(event, phase) {
    event.preventDefault()
    // iOS sends gesture events as well as touches for the same pinch; the touches win.
    if (this.touchBase) return
    const box = this.el.getBoundingClientRect()
    const x = (event.clientX ?? box.left + box.width / 2) - box.left
    const y = (event.clientY ?? box.top + box.height / 2) - box.top
    if (phase === "start") this.startPinch(x, y)
    else if (phase === "change") this.movePinch(event.scale, x, y)
    else this.endPinch()
  },

  // --- the swipe viewer ------------------------------------------------

  /** The engine the host asked for (`pager` on the component), or null: the host's own viewer. */
  pagerEngine() {
    const root = this.el.closest(".phoenix-kit-photo-timeline")
    return root ? engineFor(root.dataset.pager) : null
  },

  pagerEnabled() {
    return this.pagerEngine() !== null
  },

  /** Every position the index lists, from the first section's first file, and where each section starts. */
  resetSlides() {
    this.slides = new SlideStore(this.sections)
    this.sectionStarts = []
    let start = 0
    for (const section of this.sections) {
      this.sectionStarts.push(start)
      start += (section.days_list || []).reduce((sum, day) => sum + (day.count || 0), 0)
    }
    this.pendingOpen = null
    if (this.pager && this.pager.destroy) this.pager.destroy()
  },

  prefetchSlides(center, radius = 8) {
    if (!this.pagerEnabled() || !Number.isFinite(center)) return
    for (const block of this.slides.missing(center, radius)) {
      this.slides.markAsked(block)
      this.send("timeline:slides", {
        window: block.window,
        from: block.from,
        count: block.count,
        want: wantWidth(window),
        revision: this.revision
      })
    }
  },

  setSlides({ window: day, from, items, error, revision }) {
    if (revision !== this.revision) return
    if (error) {
      this.slides.forget(day, from)
      return
    }

    const added = this.slides.put(day, from, items || [])
    if (this.pager && this.pager.isOpen) this.pager.refresh(added)

    if (this.pendingOpen !== null && this.slides.has(this.pendingOpen)) {
      const index = this.pendingOpen
      this.pendingOpen = null
      clearTimeout(this.openTimer)
      this.openPager(index)
    }
  },

  /** A tile was clicked: the swipe viewer when the host asked for it, else the host's own. */
  openTile(id, global) {
    if (!this.pagerEnabled() || !Number.isFinite(global)) {
      this.send("timeline:open", { id })
      return
    }

    if (this.slides.has(global)) {
      this.openPager(global)
      return
    }

    // Wait for the first slide (the click usually follows a prefetch begun on pointerdown);
    // if the server does not answer, fall back to the host's viewer.
    this.pendingOpen = global
    this.prefetchSlides(global)
    clearTimeout(this.openTimer)
    this.openTimer = setTimeout(() => {
      if (this.pendingOpen === global) {
        this.pendingOpen = null
        this.send("timeline:open", { id })
      }
    }, 4000)
  },

  // The engine is loaded when first used; esbuild keeps it in the one bundle, and
  // the import keeps this file loadable without a bundler (the unit tests).
  async openPager(index) {
    if (this.pager) return
    const id = this.pagerEngine()
    if (!id) return
    this.prefetchSlides(index)

    this.pager = true // taken while the engine loads, so a second click does not open another
    let Engine
    try {
      Engine = await loadEngine(id)
    } catch (error) {
      this.pager = null
      console.error("PhotoTimeline: the viewer engine did not load", id, error)
      this.applyDeferred()
      const slide = this.slides.get(index)
      if (slide) this.send("timeline:open", { id: slide.id })
      return
    }

    this.video = this.video || new VideoController()
    this.pager = new Engine({
      store: this.slides,
      video: this.video,
      thumbOf: (slideId) => this.thumbOf(slideId),
      tileImage: (i) => this.tileImage(i),
      onInfo: (slideId) => this.send("timeline:open", { id: slideId }),
      onChange: (i) => {
        this.prefetchSlides(i)
        this.reveal(i)
      },
      onClose: () => {
        this.pager = null
        this.applyDeferred()
      }
    })
    this.pager.open(index)
  },

  thumbOf(id) {
    const node = this.pool.get(id)
    const img = node && node.querySelector("img")
    return img ? img.currentSrc || img.src : undefined
  },

  tileImage(index) {
    const slide = this.slides.get(index)
    const node = slide && this.pool.get(slide.id)
    return node ? node.querySelector("img") : null
  },

  /** Scroll the grid so the tile of `index` is on screen, for the viewer to fly back to. */
  reveal(index) {
    let found = -1
    for (let i = 0; i < this.sectionStarts.length; i++) {
      if (this.sectionStarts[i] <= index) found = i
      else break
    }
    if (found < 0) return
    const { cell, gap, header } = this.metrics
    const row = Math.floor((index - this.sectionStarts[found]) / this.columns)
    const top = this.offsets[found] + header + row * (cell + gap)
    const view = this.el.clientHeight
    // The tile must clear the header the grid scrolls under.
    if (top < this.el.scrollTop + this.inset || top + cell > this.el.scrollTop + view) {
      this.el.scrollTop = Math.max(0, top - this.inset - (view - this.inset - cell) / 2)
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
        wanted.push({
          item,
          global: this.sectionStarts[sectionIndex] + index,
          ...this.tilePosition(sectionIndex, index)
        })
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
      node.className = this.fill
        ? "pointer-events-none px-3 text-base font-semibold"
        : "pointer-events-none px-1 text-sm font-semibold"
      this.layer.appendChild(node)
      this.pool.set(id, node)
    }
    node.textContent = section.label || section.id
    const top = this.offsets[sectionIndex]
    if (this.gliding) glide(node, 0, top)
    node.style.position = "absolute"
    node.style.left = "0"
    node.style.top = `${top}px`
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

  placeTile({ item, x, y, size, global }) {
    let node = this.pool.get(item.id)
    const created = !node
    if (!node) {
      node = document.createElement("button")
      node.type = "button"
      node.dataset.fileId = item.id
      node.setAttribute("aria-label", item.kind === "video" ? "Open video" : "Open photo")
      node.className = "pointer-events-auto overflow-hidden bg-base-200 p-0"
      node.addEventListener("pointerdown", () => this.prefetchSlides(Number(node.dataset.global)))
      node.addEventListener("click", () => this.openTile(item.id, Number(node.dataset.global)))
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
    } else if (this.gliding && parseFloat(node.style.width) === size) {
      // Only a move: a change of size (zoom, resize) is laid out, not animated.
      glide(node, x, y)
    }

    node.dataset.global = String(global)
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

    if (created && this.fresh.delete(item.id)) popIn(node)
  }
}

/** Move a node from where it is to (x, y) smoothly, when it has moved. */
function glide(node, x, y) {
  if (reducedMotion() || !node.animate) return
  const dx = (parseFloat(node.style.left) || 0) - x
  const dy = (parseFloat(node.style.top) || 0) - y
  if (!dx && !dy) return
  node.animate(
    [{ transform: `translate(${dx}px, ${dy}px)` }, { transform: "translate(0, 0)" }],
    { duration: 260, easing: "cubic-bezier(0.2, 0.8, 0.2, 1)" }
  )
}

/** A new photo arrives: it grows and fades in, with a little overshoot. */
function popIn(node) {
  if (reducedMotion() || !node.animate) return
  node.animate(
    [
      { opacity: 0, transform: "scale(0.8)" },
      { opacity: 1, transform: "scale(1)" }
    ],
    { duration: 420, easing: "cubic-bezier(0.34, 1.56, 0.64, 1)" }
  )
}

function reducedMotion() {
  return typeof window !== "undefined" && window.matchMedia
    ? window.matchMedia("(prefers-reduced-motion: reduce)").matches
    : false
}

function distance(a, b) {
  return Math.hypot(a.clientX - b.clientX, a.clientY - b.clientY)
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
