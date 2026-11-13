import {
  buildOffsets,
  totalHeight,
  visibleSections,
  sectionAtOffset,
  anchorAt
} from "./geometry.js"
import { STYLES, DEFAULT_STYLE, buildLayout, decodeAspects } from "./layouts.js"
import { installTimelineCss } from "./timeline_css.js"
import { drawCalendar, today, weekLocale, weekStartFor } from "./calendar.js"
import { fillTile, markPending, markStack, pickSource, swapImage } from "./tiles.js"
import { onPreviewOffered } from "./upload_previews.js"
import { morph } from "./morph.js"
import { selection } from "./selection.js"
import { SlideStore, wantWidth } from "./slides.js"
import { StackedList } from "./stack_list.js"
import { StackStrip } from "./stack_strip.js"
import { InfoPanelController, typing } from "./info_panel.js"
import { dialogOpen, engineFor, loadEngine } from "./viewer/engine.js"
import "./viewer/engines.js"
import { VideoController } from "./viewer/video.js"

// The viewer's Add to stack: a stack with a plus on its front card.
const STACK_ADD_ICON =
  '<svg aria-hidden="true" class="pswp__icn" viewBox="0 0 32 32" width="32" height="32">' +
  '<path d="M11 8.5h11.5a1.5 1.5 0 0 1 1.5 1.5v11.5" fill="none" stroke="#fff" stroke-width="2" stroke-linecap="round"/>' +
  '<rect x="7" y="12" width="13" height="13" rx="1.5" fill="none" stroke="#fff" stroke-width="2"/>' +
  '<path d="M13.5 15.5v6M10.5 18.5h6" stroke="#fff" stroke-width="2" stroke-linecap="round"/></svg>'

// Defaults; the server may override them through the index payload.
const DEFAULTS = { cell: 160, gap: 4, header: 40 }

// Links to private files run out after a few hours (three at least, with the default window).
// A window older than this is asked for again when the tab wakes; failing tiles ask at most
// this often.
const STALE_AFTER_MS = 60 * 60 * 1000
const RELOAD_EVERY_MS = 10 * 1000

// A viewer's own address change comes back from the server a moment later as a "view" of the
// same photo; while the viewer is open that echo must not pull the person back to it.
const ECHO_MS = 5 * 1000

// A photo's address opens the viewer in the index that answers the hook's hello, not in the one
// sent with the page: the server moves to a new revision on the hello and refuses windows asked
// for in the old one. A server that never answers (an index it could not read) must not keep
// the address from opening for good.
const HELLO_WAIT_MS = 3 * 1000

// Zoom: the smallest tile a person can pinch down to, and where the choice is remembered.
const MIN_CELL = 56
const ZOOM_KEY = "phoenix_kit_photos:cell"

// The style a person picked, and how long a style that shows whole photos waits for the aspect
// ratios before it makes do with each month's average.
const STYLE_KEY = "phoenix_kit_photos:style"
const ASPECTS_WAIT_MS = 1500

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
  ...selection,

  // Height of the header the grid scrolls under (see `readInset`).
  inset: 0,
  // A pinch in progress, and the tile size a pinch chose (see "zoom" below).
  pinch: null,
  zoomCell: null,
  // The address follows the swipe viewer (see "addresses" below): whether the address already
  // names the open photo, whether the viewer opened by adding a history entry of its own,
  // whether the server is closing it, the photos whose address was just set, and a "view" the
  // server sent before the index it needs arrived.
  addressOpen: false,
  addressPushed: false,
  addressHistoryId: null,
  addressClosing: false,
  addressSent: null,
  view: null,
  // The style on screen (see "styles" below), and the aspect ratios of the files, by section.
  styleId: DEFAULT_STYLE,
  aspects: null,

  mounted() {
    // A tile being prepared takes the uploader's picture of its file the moment there is one.
    this.stopPreviewOffers = onPreviewOffered((fileId) => {
      const node = this.pool?.get(fileId)
      const img = node?.querySelector("img:last-of-type")
      const item = node?.dataset.pending !== undefined && { id: fileId, pending: true }
      const src = item && pickSource(item, 0, 0, this.style())
      if (img && src && img.dataset.src !== src) {
        img.dataset.src = src
        img.src = src
      }
    })
    // The virtual grid owns scroll restoration. Browser anchoring must not
    // compensate again when recycled tiles or the spacer change.
    this.el.style.overflowAnchor = "none"
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
    // When each window arrived, and when a failing tile last made us ask for them again.
    this.fetchedAt = new Map()
    this.lastReload = 0
    // Files this library has shown us, and which of them just arrived (see `noteArrivals`).
    this.known = new Set()
    this.fresh = new Set()
    // Windows asked for again because storage changed, answered by `setWindow`.
    this.refreshing = new Set()
    this.pool = new Map()
    this.library = null
    this.revision = null
    this.needed = new Set()
    this.aspects = new Map()
    this.slides = new SlideStore([])
    this.sectionStarts = []
    this.pager = null
    this.pendingOpen = null
    this.frozenAnchor = null

    this.spacer = this.el.querySelector(".phoenix-kit-photo-timeline__spacer")
    this.layer = this.el.querySelector(".phoenix-kit-photo-timeline__layer")

    installTimelineCss()
    this.lang = document.documentElement.lang || navigator.language
    this.weekStart = weekStartFor(weekLocale(this.lang, navigator.languages || [navigator.language]))
    this.styleId = this.startingStyle()
    this.el.dataset.activeStyle = this.styleId
    this.bindStyleMenu()
    this.bindSelection()

    this.mountBookmark()
    this.onPositionInput = event => this.beginPositionInput(event)
    this.positionInputs = ["wheel", "touchmove", "pointerdown", "keydown"]
    for (const event of this.positionInputs) this.el.addEventListener(event, this.onPositionInput, { passive: true })

    this.onScroll = throttleToFrame(() => this.handleScroll())
    this.el.addEventListener("scroll", this.onScroll, { passive: true })

    this.bindZoom()

    // The links in a window can run out (see `reloadWindows`). An image's `error` does not
    // bubble, so listen on the way down.
    this.onImageError = () => this.imageFailed()
    this.layer.addEventListener("error", this.onImageError, true)
    this.onPageHide = () => this.freezePosition()
    window.addEventListener("pagehide", this.onPageHide)
    this.onWake = () => {
      if (document.visibilityState === "hidden") this.freezePosition()
      if (document.visibilityState === "visible") {
        this.handleScroll()
        this.reloadWindows({ olderThan: STALE_AFTER_MS })
      }
    }
    document.addEventListener("visibilitychange", this.onWake)
    window.addEventListener("pageshow", this.onWake)
    this.onWindowBlur = () => this.freezePosition()
    this.onWindowFocus = () => { this.freezePosition(); this.handleScroll() }
    window.addEventListener("blur", this.onWindowBlur)
    window.addEventListener("focus", this.onWindowFocus)

    this.onResize = debounce(() => this.handleResize(), 120)
    window.addEventListener("resize", this.onResize)
    this.resizeObserver = new ResizeObserver(this.onResize)
    this.resizeObserver.observe(this.el)

    const prefix = `timeline:${this.el.dataset.timelineId}`
    this.handleEvent(`${prefix}:index`, (payload) => this.setIndex(payload))
    this.handleEvent(`${prefix}:window`, (payload) => this.setWindow(payload))
    this.handleEvent(`${prefix}:jump`, ({ id }) => this.jumpTo(id))
    this.handleEvent(`${prefix}:view`, (payload) => this.applyView(payload))
    this.handleEvent(`${prefix}:slides`, (payload) => this.setSlides(payload))
    this.handleEvent(`${prefix}:stack`, (payload) => this.setStack(payload))
    this.handleEvent(`${prefix}:aspects`, (payload) => this.setAspects(payload))
    this.handleEvent(`${prefix}:range`, (payload) => this.applyRange(payload))
    this.handleEvent(`${prefix}:selection`, (payload) => this.applySelection(payload))
    this.handleEvent(`${prefix}:links`, (payload) => this.showLinks(payload))
    this.bindInfo()
    // A title changed in the info panel: the viewer's caption says it at once.
    this.handleEvent("photos:retitle", ({ id, title }) => this.retitle(id, title))
    this.sayHello()
  },

  send(event, payload) {
    this.pushEventTo(Number(this.el.dataset.target), event, payload)
  },

  /** Ask for the index. Until the answer (`hello: true`) arrives, what the page holds may be old. */
  sayHello() {
    this.indexCurrent = false
    clearTimeout(this.helloTimer)
    this.helloTimer = setTimeout(() => {
      this.indexCurrent = true
      this.openFromAddress()
    }, HELLO_WAIT_MS)
    this.send("timeline:ready", this.readyPayload())
  },

  disconnected() {
    this.freezePosition()
  },

  reconnected() {
    this.handleScroll()
    this.sayHello()
    this.reloadWindows({ olderThan: STALE_AFTER_MS })
  },

  destroyed() {
    this.stopPreviewOffers?.()
    for (const event of this.positionInputs) this.el.removeEventListener(event, this.onPositionInput)
    this.bookmarkMark?.remove()
    window.removeEventListener("pagehide", this.onPageHide)
    this.unbindZoom()
    this.el.removeEventListener("scroll", this.onScroll)
    this.layer.removeEventListener("error", this.onImageError, true)
    document.removeEventListener("visibilitychange", this.onWake)
    window.removeEventListener("pageshow", this.onWake)
    window.removeEventListener("blur", this.onWindowBlur)
    window.removeEventListener("focus", this.onWindowFocus)
    clearTimeout(this.positionInputTimer)
    window.removeEventListener("resize", this.onResize)
    this.unbindStyleMenu()
    this.unbindSelection()
    clearTimeout(this.aspectsTimer)
    this.resizeObserver.disconnect()
    this.onResize.cancel()
    this.onScroll.cancel()
    clearTimeout(this.openTimer)
    clearTimeout(this.helloTimer)
    // The page is going: the viewer's closing must not touch the address.
    this.addressClosing = true
    if (this.pager && this.pager.destroy) this.pager.destroy()
    if (this.strip) this.strip.destroy()
    this.unbindInfo()
    this.stopStackKeys()
    this.pool.clear()
  },

  setIndex(payload) {
    if (payload.hello) {
      this.indexCurrent = true
      clearTimeout(this.helloTimer)
    }
    const libraryChanged = payload.library !== this.library
    // The grid behind the swipe viewer catches up when the viewer closes; the viewer's own
    // list moves to the new index now (`rebaseViewer`). The server sends a month's ratios only
    // once, so a later refresh must not lose them.
    if (!libraryChanged && this.pager) {
      const aspects = { ...this.deferred?.aspects, ...payload.aspects }
      this.deferred = { ...payload, aspects }
      this.rebaseViewer(payload)
      return
    }

    // Storage changed under a library already on screen: a refresh, not a new library. The
    // tiles stay where they are while the windows are fetched again, and what is new arrives
    // with an animation.
    const refresh = !libraryChanged && this.revision !== null
    const anchor = libraryChanged ? null :
      this.positionInput ? this.captureAnchor() : this.bookmarkAnchor || this.captureAnchor()
    const atEnd = refresh && this.atEnd() && (!this.bookmarkAnchor ||
      Math.abs((this.offsets[this.bookmarkAnchor.index] || 0) + this.bookmarkAnchor.delta - this.inset - this.el.scrollTop) < 2)
    const heightBefore = totalHeight(this.offsets)

    if (libraryChanged) this.rememberPosition()
    this.library = payload.library
    if (payload.revision === this.revision && !libraryChanged) {
      this.openFromAddress()
      return
    }
    this.revision = payload.revision
    if (libraryChanged) {
      this.windows.clear()
      this.known.clear()
      this.aspects?.clear()
      // What was chosen was chosen in the last library.
      this.selected?.clear()
      this.selectMode = false
      this.selectAnchor = null
    }
    this.fresh.clear()
    this.refreshing.clear()
    // A position means another photo once the index has changed.
    this.selectAnchor = null

    this.sections = payload.sections || []
    this.storeAspects(payload.aspects)
    if (!this.styleFits(this.styleId)) {
      this.styleId = DEFAULT_STYLE
      if (this.el.dataset) this.el.dataset.activeStyle = DEFAULT_STYLE
    }
    this.resetSlides()
    if (payload.metrics) {
      const { gap, ...rest } = payload.metrics
      this.metrics = { ...this.metrics, ...rest }
      if (this.el.dataset.gap === undefined && gap !== undefined) this.metrics.gap = gap
    }
    const saved = libraryChanged ? this.storedPosition() : null
    this.recordPosition("index", { libraryChanged, saved: Boolean(saved) })
    if (libraryChanged) this.frozenAnchor = saved?.anchor || null
    this.relayout(this.frozenAnchor || saved?.anchor || anchor)

    if (libraryChanged && !saved) {
      const height = totalHeight(this.offsets)
      this.el.scrollTop = Math.max(0, height - this.el.clientHeight)
    } else if (!this.frozenAnchor && atEnd && totalHeight(this.offsets) > heightBefore) {
      this.followEnd()
    }

    if (libraryChanged) {
      this.bookmarkAnchor = saved?.anchor || this.captureAnchor()
      if (!saved) this.rememberPosition()
    }
    this.markStyle(this.styleId)
    if (refresh) this.revalidate()
    // Nothing shown yet (the page's index was overtaken by the hello's) means nothing is new.
    this.popNew = refresh && this.known.size > 0
    this.markNew = refresh
    this.handleScroll()
    this.markNew = false
    this.selectionChanged()
    this.openFromAddress()
  },

  // A quiet row-boundary marker follows the position saved for this tab.
  mountBookmark() {
    this.bookmarkMark = document.createElement("div")
    this.bookmarkMark.dataset.bookmarkMarker = ""
    this.bookmarkMark.setAttribute("aria-hidden", "true")
    this.bookmarkMark.style.cssText = "position:absolute;left:8px;z-index:12;pointer-events:none;width:0;height:0"
    const tab = document.createElement("span")
    tab.style.cssText = "position:absolute;left:0;top:0;width:10px;height:10px;background:#fbbf24;border:1px solid #18181bcc;border-radius:1px;transform:translateY(-50%) rotate(45deg);box-shadow:0 1px 2px #0005;opacity:0.85"
    this.bookmarkMark.append(tab)
    this.el.append(this.bookmarkMark)
  },

  beginPositionInput(event) {
    if (event.type === "keydown" && (!/^(ArrowUp|ArrowDown|PageUp|PageDown|Home|End| )$/.test(event.key) ||
        /^(INPUT|TEXTAREA|SELECT)$/.test(event.target?.tagName || "") || event.target?.isContentEditable)) return
    // Clicking the window to activate Safari is not a request to move the bookmark.
    if (event.type === "pointerdown" && event.clientX < this.el.getBoundingClientRect().right - 16) return
    this.frozenAnchor = null
    this.positionInput = true
    this.extendPositionInput()
  },

  extendPositionInput() {
    clearTimeout(this.positionInputTimer)
    this.positionInputTimer = setTimeout(() => { this.positionInput = false }, 250)
  },

  freezePosition() {
    this.positionInput = false
    clearTimeout(this.positionInputTimer)
    // Use the last settled position, before any browser-generated wake scroll.
    if (!this.frozenAnchor) this.frozenAnchor = this.bookmarkAnchor || this.captureAnchor()
    this.recordPosition("freeze")
  },

  saveBookmark() {
    if (this.frozenAnchor) {
      this.bookmarkAnchor = this.frozenAnchor
      this.renderBookmark()
      return
    }
    if (!this.library || !this.sections.length || this.pager) return
    // Geometry updates and browser scroll restoration must never become a new bookmark.
    if (this.bookmarkAnchor && !this.positionInput) {
      this.renderBookmark()
      return
    }
    if (this.positionInput) this.extendPositionInput()
    this.bookmarkAnchor = this.captureAnchor()
    this.rememberPosition()
    this.renderBookmark()
  },

  /**
   * Where the marker goes: the gap above the first row (or photo) that starts at or below the
   * saved place, so it shows below the app header. That row may be in a later month, when the
   * place was in a month's last row.
   */
  bookmarkTop() {
    const a = this.bookmarkAnchor
    if (!a) return null
    const index = this.sections.findIndex(s => s.id === a.id)
    if (index < 0) return null
    const line = this.offsets[index] + this.anchorDelta(a, index)
    for (let i = index; i < this.sections.length; i++) {
      const layout = this.layoutOf(this.sections[i])
      const edge = layout.edgeBelow(line - this.offsets[i])
      if (edge === null) continue
      const gap = edge > layout.header + 0.5 ? Math.max(0, layout.gapY) / 2 : 0
      return this.offsets[i] + edge - gap
    }
    return line
  },

  /**
   * How far into its section an anchor is, px: its own measure while the page has the same
   * geometry, else worked out again from the tile it names (the columns, zoom or style changed).
   */
  anchorDelta(anchor, index) {
    const fraction = Number.isFinite(anchor.rowFraction) ? Math.max(0, Math.min(1, anchor.rowFraction)) : 0
    const unchanged = anchor.columns === this.columns && anchor.cell === this.metrics.cell &&
      anchor.header === this.metrics.header && anchor.gap === this.metrics.gap &&
      (anchor.style ?? DEFAULT_STYLE) === this.styleId
    return unchanged && Number.isFinite(anchor.delta)
      ? anchor.delta
      : anchor.headerOffset + this.layoutOf(this.sections[index]).contentY(anchor.item, fraction)
  },

  renderBookmark() {
    if (!this.bookmarkMark) return
    const top = this.bookmarkTop()
    this.bookmarkMark.style.display = top === null ? "none" : "block"
    if (top !== null) this.bookmarkMark.style.top = `${top}px`
  },

  // A bounded local trace makes an intermittent wake failure inspectable without
  // recording photos, file URLs, or account details.
  recordPosition(event, details = {}) {
    try {
      const key = "phoenix_kit_photos:position_log"
      const entries = JSON.parse(window.sessionStorage.getItem(key) || "[]")
      entries.push({ event, at: Date.now(), top: this.el.scrollTop,
        section: this.bookmarkAnchor?.id, item: this.bookmarkAnchor?.item,
        frozen: Boolean(this.frozenAnchor), ...details })
      window.sessionStorage.setItem(key, JSON.stringify(entries.slice(-40)))
    } catch (_error) {
      // Diagnostics must never interrupt the library.
    }
  },

  positionKey() {
    return `phoenix_kit_photos:position:${this.el.dataset.timelineId}:${this.library}`
  },

  storedPosition() {
    // Keep independent positions in open tabs; fall back to the last durable
    // position when Safari reopens without the old tab's sessionStorage.
    for (const name of ["sessionStorage", "localStorage"]) {
      try {
        const saved = JSON.parse(window[name].getItem(this.positionKey()))
        const a = saved?.anchor
        if (a && typeof a.id === "string" && Number.isInteger(a.index) && a.index >= 0 &&
            Number.isFinite(a.item) && a.item >= 0 &&
            Number.isFinite(a.headerOffset) && a.headerOffset >= 0) return saved
      } catch (_error) {
        // One storage type may be unavailable, or contain an older bookmark.
      }
    }
    return null
  },

  rememberPosition() {
    if (this.frozenAnchor) return
    if (!this.library || !this.sections.length) return
    const value = JSON.stringify({ anchor: this.bookmarkAnchor || this.captureAnchor() })
    for (const name of ["sessionStorage", "localStorage"]) {
      try {
        window[name].setItem(this.positionKey(), value)
      } catch (_error) {
        // Keep browsing and still try the other storage type.
      }
    }
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
    return this.layoutOf(section).height
  },

  /** Where everything in a section goes in the style on screen (see layouts.js). */
  layoutOf(section) {
    const { cell, gap, header } = this.metrics
    const key = `${this.styleId}:${this.columns}:${cell}:${gap}:${header}`
    if (key !== this.layoutKey || !this.layouts) {
      this.layoutKey = key
      this.layouts = new WeakMap()
    }
    let layout = this.layouts.get(section)
    if (!layout) {
      layout = buildLayout(this.styleId, {
        count: section.count,
        aspectAt: this.aspectReader(section),
        columns: this.columns,
        width: this.columns * (cell + gap) - gap,
        cell,
        gap,
        header,
        month: section.id,
        days: section.days_list,
        weekStart: this.weekStart,
        today: today()
      })
      this.layouts.set(section, layout)
    }
    return layout
  },

  /** The aspect ratio of each file of a section; the month's average while they are unknown. */
  aspectReader(section) {
    const known = this.aspects?.get(section.id)
    if (known && known.length === section.count) return (index) => known[index]
    const average = section.count > 0 && section.sum_aspect > 0 ? section.sum_aspect / section.count : 1.4
    return () => average
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
    const section = this.sections[anchor.index]
    const { item, fraction } = section
      ? this.layoutOf(section).anchor(anchor.delta)
      : { item: 0, fraction: 0 }
    return {
      id: section?.id,
      index: anchor.index,
      delta: anchor.delta,
      columns: this.columns,
      cell: this.metrics.cell,
      header: this.metrics.header,
      gap: this.metrics.gap,
      style: this.styleId,
      headerOffset: Math.min(anchor.delta, this.metrics.header),
      // The place in the section as a count of tiles, so it survives a change of columns.
      item,
      rowFraction: fraction
    }
  },

  /** The height, in px, of what the grid scrolls under: `--photo-timeline-inset-top` (any CSS length). */
  readInset() {
    if (typeof getComputedStyle !== "function") return 0
    const value = getComputedStyle(this.el).getPropertyValue("--photo-timeline-inset-top").trim()
    if (!value) return 0
    // Resolve rem, calc() and env() the way the browser does: let it size a probe.
    const probe = document.createElement("div")
    probe.style.cssText = `position:fixed;top:0;left:0;visibility:hidden;pointer-events:none;height:${value}`
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
      const delta = found < 0 ? 0 : this.anchorDelta(anchor, index)
      this.el.scrollTop = Math.max(0, this.offsets[index] + delta - this.inset)
    }
  },

  handleResize() {
    this.relayout()
    this.handleScroll()
  },

  handleScroll() {
    if (this.frozenAnchor && this.sections.length) {
      const before = this.el.scrollTop
      this.relayout(this.frozenAnchor)
      if (Math.abs(before - this.el.scrollTop) > 1) this.recordPosition("restore", { before })
    }
    const indices = visibleSections(this.offsets, this.el.scrollTop, this.el.clientHeight)
    this.needed = new Set()
    for (const i of indices) this.ensureVisibleDays(this.sections[i])
    for (const day of this.windows.keys()) {
      if (!this.needed.has(day)) {
        this.windows.delete(day)
        this.fetchedAt.delete(day)
      }
    }
    this.materialize(indices)
    this.showCurrent()
    this.saveBookmark()
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
    this.fetchedAt.set(section, Date.now())
    this.noteArrivals(items || [], arrived)
    // Tiles that move because of what arrived glide to their places.
    this.gliding = arrived
    this.handleScroll()
    this.gliding = false
    // A box being drawn takes in what has just arrived under it.
    if (this.drag?.box) this.drawBox()
  },

  /**
   * Ask again for the windows on screen, and keep showing the old ones until the answers come.
   *
   * A private file's links stop working after a few hours, and a window holds its links for as
   * long as its day is on screen, so a tab left open (or put to sleep and woken) is showing
   * links the server now refuses. The new answer carries fresh links; `placeTile` loads the
   * tiles whose link changed and leaves the rest alone. `olderThan` skips windows that came
   * lately.
   */
  reloadWindows({ olderThan = 0 } = {}) {
    const now = Date.now()
    for (const [day, items] of this.windows) {
      if (items === null) continue
      if (now - (this.fetchedAt.get(day) || 0) < olderThan) continue
      this.send("timeline:need_window", { window: day, revision: this.revision })
    }
  },

  /**
   * A tile's image failed. The likely reason is an expired link, so reload the windows. A burst
   * of failures (a whole screen of tiles) asks once, and a picture that is truly gone cannot
   * start a loop: its new link equals the old one, so it is not requested again.
   */
  imageFailed() {
    const now = Date.now()
    if (now - this.lastReload < RELOAD_EVERY_MS) return
    this.lastReload = now
    this.reloadWindows()
  },

  /**
   * Remember the files of a window. When the window was fetched again because storage changed,
   * the ones never seen before are the new photos: they will pop in.
   */
  noteArrivals(items, arrived) {
    for (const item of items) {
      if (arrived && this.popNew && !this.known.has(item.id)) this.fresh.add(item.id)
      this.known.add(item.id)
    }
  },

  /** Jump to a section id, e.g. "2018-07". */
  jumpTo(sectionId) {
    this.frozenAnchor = null
    this.positionInput = true
    this.extendPositionInput()
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
    return { index, item: this.layoutOf(section).hit(x, this.el.scrollTop + y - this.offsets[index]) }
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
    this.beginPositionInput({ type: "wheel" })
    const [low, high] = this.cellLimits()
    const focus = this.itemAtPoint(x, y)
    this.zoomCell = Math.min(high, Math.max(low, cell))
    this.relayout(null)
    if (focus) this.el.scrollTop = Math.max(0, this.tileMiddle(focus) - y)
    this.handleScroll()
    this.rememberZoom()
  },

  /** The height in the library of the middle of a tile. */
  tileMiddle({ index, item }) {
    const { y, h } = this.layoutOf(this.sections[index]).rect(item)
    return this.offsets[index] + y + h / 2
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
    this.beginPositionInput({ type: "wheel" })
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
    this.slideRevision = this.revision
    this.following = null
    this.sectionStarts = []
    let start = 0
    for (const section of this.sections) {
      this.sectionStarts.push(start)
      start += (section.days_list || []).reduce((sum, day) => sum + (day.count || 0), 0)
    }
    this.pendingOpen = null
    if (this.pager && this.pager.destroy) {
      // Gone because the positions changed under it, not because the person closed it.
      this.addressClosing = true
      this.pager.destroy()
    }
  },

  /**
   * A new index while the viewer is open (an upload): the viewer's slides move to it at once,
   * while the grid behind waits for the close (`applyDeferred`). What the viewer asks for next
   * is asked in the new revision, which the server answers; asked in the old one, it was
   * refused, and the viewer waited for good on the first photo it had not fetched.
   */
  rebaseViewer(payload) {
    this.slideRevision = payload.revision
    const open = this.pager !== true && this.pager.isOpen
    const index = open ? this.pager.index : -1
    // The viewer's position is in the list with stacks opened; the timeline's is the cover's.
    const where = open ? this.stacked().fromView(index) : null
    const shown = open ? this.stacked().get(index) : null
    const slide = open ? this.slides.get(where.at) : null
    const at = this.slides.rebase(payload.sections, open ? { index: where.at, slide } : null)
    // A stack's pages may have changed (a photo added or taken out, a new cover): asked for
    // again, and the viewer follows the photo it shows if that went into a stack.
    this.stacked().refreshAll()
    if (!open) return

    const to = at >= 0 ? this.stacked().toView(at, where.page) : -1
    if (to >= 0 && to !== index && this.pager.goTo) {
      this.turningTo = to
      this.pager.goTo(to)
    }
    // A photo added earlier in the same day moves the one on screen along: once that day's
    // slides arrive, `setSlides` turns to where it went.
    this.following = shown ? shown.id : null
    const center = at >= 0 ? at : Math.min(where.at, Math.max(0, this.slides.total - 1))
    this.prefetchSlides(center)
    this.prefetchStacks(center)
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
        revision: this.slideRevision
      })
    }
  },

  /** Ask for the pages of the stacks within `radius` of timeline position `center`. */
  prefetchStacks(center, radius = 3) {
    if (!this.pagerEnabled() || !Number.isFinite(center)) return
    for (const { id, cover } of this.stacked().wanted(center - radius, center + radius)) {
      this.send("timeline:stack", { stack: id, cover, want: wantWidth(window), revision: this.slideRevision })
    }
  },

  /** A stack's pages arrived: they open in line, and the viewer stays on the photo it shows. */
  setStack({ stack, cover, pages, error, revision }) {
    if (revision !== this.slideRevision) return
    if (error) {
      this.stacked().forget(stack)
      return
    }

    const open = this.pager && this.pager !== true && this.pager.isOpen
    const shown = open ? this.stacked().get(this.pager.index) : null
    this.stacked().expand(stack, cover, pages || [])
    if (!open) return

    const want = this.following ? this.stacked().indexOf(this.following) : -1
    const at = want >= 0 ? want : shown ? this.stacked().indexOf(shown.id) : -1
    if (want >= 0) this.following = null
    if (at >= 0 && at !== this.pager.index && this.pager.goTo) {
      this.turningTo = at
      this.pager.goTo(at)
    } else if (want >= 0 && at === this.pager.index) {
      // Already at its place, but what was drawn there was something else.
      this.pager.refresh([at])
    }
    if (this.pager.redraw) this.pager.redraw()
    this.showStrip(this.pager.index)
  },

  setSlides({ window: day, from, items, error, revision }) {
    if (revision !== this.slideRevision) return
    if (error) {
      this.slides.forget(day, from)
      return
    }

    const added = this.slides.put(day, from, items || [])
    if (this.following && this.pager && this.pager !== true && this.pager.isOpen) {
      const at = this.stacked().indexOf(this.following)
      if (at >= 0) {
        this.following = null
        if (at !== this.pager.index && this.pager.goTo) {
          this.turningTo = at
          this.pager.goTo(at)
        }
      }
    }
    if (this.pager && this.pager.isOpen) {
      this.pager.refresh(added.map((at) => this.stacked().toView(at)))
      this.prefetchStacks(this.stacked().fromView(this.pager.index).at)
    }

    if (this.pendingOpen !== null && this.slides.has(this.pendingOpen)) {
      const index = this.pendingOpen
      this.pendingOpen = null
      clearTimeout(this.openTimer)
      this.openPager(this.stacked().toView(index))
    }
  },

  /** A tile was clicked: the swipe viewer when the host asked for it, else the host's own. */
  openTile(id, global) {
    if (!this.pagerEnabled() || !Number.isFinite(global)) {
      this.send("timeline:open", { id })
      return
    }

    if (this.slides.has(global)) {
      this.openPager(this.stacked().toView(global))
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
  // `index` is a position in the viewer's list (`this.list`: the timeline with stacks opened).
  async openPager(index) {
    if (this.pager) return
    const id = this.pagerEngine()
    if (!id) return
    this.prefetchSlides(this.stacked().fromView(index).at)

    this.pager = true // taken while the engine loads, so a second click does not open another
    let Engine
    try {
      Engine = await loadEngine(id)
    } catch (error) {
      this.pager = null
      console.error("PhotoTimeline: the viewer engine did not load", id, error)
      this.applyDeferred()
      const slide = this.stacked().get(index)
      if (slide) this.send("timeline:open", { id: slide.id })
      return
    }

    this.video = this.video || new VideoController()
    this.pager = new Engine({
      store: this.stacked(),
      video: this.video,
      thumbOf: (slideId) => this.thumbOf(slideId),
      tileImage: (i) => this.tileImage(i),
      onInfo: (slideId) => this.info && this.info.toggle(slideId),
      actions: this.viewerActions(),
      onChange: (i) => {
        // The person turned the page: stop following a photo an upload moved.
        if (i !== this.turningTo) this.following = null
        this.turningTo = null
        const at = this.stacked().fromView(i).at
        this.prefetchSlides(at)
        this.prefetchStacks(at)
        this.reveal(at)
        this.syncAddress(i)
        this.showStrip(i)
        const slide = this.stacked().get(i)
        if (this.info && slide) this.info.follow(slide.id)
      },
      onClose: () => {
        this.pager = null
        this.following = null
        if (this.info) this.info.close({ remember: false })
        if (this.strip) this.strip.hide()
        this.stopStackKeys()
        this.applyDeferred()
        this.leaveAddress()
      }
    })
    this.pager.open(index)
    const opened = this.stacked().get(index)
    if (this.info && opened) this.info.viewerOpened(opened.id)
    this.syncAddress(index)
    this.startStackKeys()
    this.prefetchStacks(this.stacked().fromView(index).at)
    this.showStrip(index)
  },

  // --- the info panel ---------------------------------------------------------

  /**
   * The info panel (`info_panel.js`): the Info button and `i` open and close it, and it follows
   * the photo on screen. Its own buttons send DOM events: `photos:info-close`, and
   * `photos:info-more` for the host's full viewer (every detail of the file).
   */
  bindInfo() {
    const panelId = this.root()?.dataset.infoPanel
    if (!panelId || !this.pagerEnabled()) return

    this.info = new InfoPanelController({
      element: () => document.getElementById(panelId),
      show: (id) => this.send("timeline:info", { id }),
      resize: () => {
        if (this.pager && this.pager !== true && this.pager.resize) this.pager.resize()
        if (this.strip && this.strip.place) this.strip.place()
      },
      current: () => {
        const open = this.pager && this.pager !== true && this.pager.isOpen
        const slide = open ? this.stacked().get(this.pager.index) : null
        return slide ? slide.id : null
      }
    })

    this.onInfoClose = () => this.info && this.info.close()
    this.onInfoMore = (event) => {
      const id = event.detail && event.detail.id
      if (id) this.send("timeline:open", { id })
    }
    this.onInfoKey = (event) => {
      if (event.key !== "i" && event.key !== "I") return
      if (event.altKey || event.ctrlKey || event.metaKey || typing(event.target) || dialogOpen()) return
      const id = this.info.host.current()
      if (!id) return
      event.preventDefault()
      this.info.toggle(id)
    }
    window.addEventListener("photos:info-close", this.onInfoClose)
    window.addEventListener("photos:info-more", this.onInfoMore)
    document.addEventListener("keydown", this.onInfoKey)
  },

  retitle(id, title) {
    const at = this.slides ? this.slides.indexOf(id) : -1
    const slide = at >= 0 ? this.slides.get(at) : null
    if (slide) slide.title = title
    for (const stack of this.list?.stacks?.values() || []) {
      for (const page of stack?.pages || []) if (page.id === id) page.title = title
    }
    if (this.pager && this.pager !== true && this.pager.caption) this.pager.caption()
  },

  unbindInfo() {
    if (!this.info) return
    this.info.destroy()
    window.removeEventListener("photos:info-close", this.onInfoClose)
    window.removeEventListener("photos:info-more", this.onInfoMore)
    document.removeEventListener("keydown", this.onInfoKey)
    this.info = null
  },

  // --- a stack's pages in the viewer ---------------------------------------

  /**
   * The viewer's list: the timeline's slides with each stack whose pages are here opened in
   * line (`stack_list.js`). Made again whenever the slides are (a new index).
   */
  stacked() {
    if (!this.list || this.list.store !== this.slides) this.list = new StackedList(this.slides)
    return this.list
  },

  /** The translated words of the stack strip and buttons (`data-stack-strings`). */
  stackStrings() {
    try {
      return JSON.parse(this.root()?.dataset.stackStrings || "{}")
    } catch (_error) {
      return {}
    }
  },

  /**
   * The viewer's own buttons (`host.actions`): Add to stack, on a photo in no stack, for someone
   * who may change the library. The photo goes into a stack picked in a dialog, and the viewer
   * follows it there.
   */
  viewerActions() {
    if (this.root()?.dataset.stackEdit !== "true") return []
    const single = (i) => {
      const slide = this.stacked().get(i)
      return slide && !this.stacked().pageInfo(i) && !(slide.stack && slide.stack.count >= 2) ? slide : null
    }
    return [
      {
        name: "stack-add",
        label: this.stackStrings().add || "Add to stack",
        icon: STACK_ADD_ICON,
        shown: (i) => single(i) !== null,
        run: (i) => {
          const slide = single(i)
          if (slide) this.send("timeline:pick_stack", { file: slide.id })
        }
      }
    ]
  },

  /** The strip over a stack's photo (`stack_strip.js`), or nothing off a stack. */
  showStrip(index) {
    const open = this.pager && this.pager !== true && this.pager.isOpen
    if (open && this.pager.syncActions) this.pager.syncActions()
    const info = open ? this.stacked().pageInfo(index) : null
    if (!info) {
      if (this.strip) this.strip.hide()
      return
    }
    if (!this.strip) {
      const root = this.root()
      this.strip = new StackStrip({
        strings: this.stackStrings(),
        editable: root?.dataset.stackEdit === "true",
        onGo: (to) => this.turnTo(to),
        onSkip: (direction) => this.skipStack(direction),
        onEdit: (shown) => {
          const slide = this.pager && this.pager !== true ? this.stacked().get(this.pager.index) : null
          if (slide) this.send("timeline:stack_edit", { stack: shown.id, file: slide.id })
        }
      })
    }
    this.strip.update(info)
  },

  turnTo(index) {
    if (!this.pager || this.pager === true || !this.pager.goTo) return
    if (index < 0 || index >= this.stacked().total || index === this.pager.index) return
    this.pager.goTo(index)
  },

  /** Past the stack on screen: to the photo after it (1) or before it (-1). */
  skipStack(direction) {
    if (!this.pager || this.pager === true) return
    const info = this.stacked().pageInfo(this.pager.index)
    if (!info) return
    this.turnTo(direction > 0 ? info.last + 1 : info.first - 1)
  },

  // ↓ and ↑ (and Page Down, Page Up) skip a stack while the viewer is on one; the engine's own
  // keys turn single pages. A dialog over the viewer has the keys to itself.
  startStackKeys() {
    if (this.onStackKey) return
    this.onStackKey = (event) => {
      if (event.altKey || event.ctrlKey || event.metaKey || event.shiftKey || dialogOpen()) return
      const direction = { ArrowDown: 1, PageDown: 1, ArrowUp: -1, PageUp: -1 }[event.key]
      if (!direction || !this.pager || this.pager === true || !this.stacked().pageInfo(this.pager.index)) return
      event.preventDefault()
      event.stopPropagation()
      this.skipStack(direction)
    }
    document.addEventListener("keydown", this.onStackKey, true)
  },

  stopStackKeys() {
    if (!this.onStackKey) return
    document.removeEventListener("keydown", this.onStackKey, true)
    this.onStackKey = null
  },

  // --- addresses: the page's address follows the swipe viewer -------------
  //
  // With `data-photo-path` ("/anna/private/p/:code") and `data-library-path` on the root, opening
  // the viewer adds a history entry for the photo, turning the page replaces it, and closing
  // goes back. The changes are made through LiveView (`js().patch`), never `history.pushState`:
  // LiveView takes an entry it did not make for a page to reload. The host's `handle_params`
  // sees every address, and tells the hook, by "view", which photo the address names (on load,
  // and after Back or Forward), so a link to a photo opens it and Back closes it.

  /** The two addresses the host gave, or null: then nothing here does anything. */
  addresses() {
    const root = this.el.closest(".phoenix-kit-photo-timeline")
    const photo = root && root.dataset.photoPath
    const library = root && root.dataset.libraryPath
    return photo && library && photo.includes(":code") ? { photo, library } : null
  },

  /** Whether the page is at the address of some photo. */
  atPhotoAddress(paths) {
    const [before, after] = paths.photo.split(":code")
    const path = window.location.pathname
    return path.startsWith(before) && path.endsWith(after) && path.length > before.length + after.length
  },

  /**
   * The viewer shows slide `index`: put the photo's address in the bar. The first call after
   * the viewer opened adds a history entry (unless the page was opened on this photo already),
   * the rest replace it.
   */
  syncAddress(index) {
    const paths = this.addresses()
    const slide = this.stacked().get(index)
    if (!paths || !slide || !slide.code) return

    const to = paths.photo.replace(":code", encodeURIComponent(slide.code))
    this.noteSent(slide.id)
    if (window.location.pathname === to) {
      this.addressOpen = true
      return
    }

    // Opening can report the same slide twice before LiveView commits the first
    // patch (the engine's change event, then openPager). A newer patch supersedes
    // the older one, so keep pushing until the browser actually has a photo URL;
    // replacing sooner would erase the library entry that Close goes back to.
    const push = !this.atPhotoAddress(paths)
    if (!this.addressOpen) this.addressHistoryId = window.history.state?.id || null
    this.addressOpen = true
    if (push) this.addressPushed = true
    this.js().patch(to, { replace: !push })
  },

  /** Remember that the address of this photo was just set, for `applyView` to recognise the echo. */
  noteSent(id) {
    const now = Date.now()
    const sent = (this.addressSent = this.addressSent || new Map())
    for (const [other, at] of sent) if (now - at > ECHO_MS) sent.delete(other)
    sent.set(id, now)
  },

  /**
   * The viewer is gone. Unless the server closed it (Back), the address leaves the photo: back
   * to the entry before it when the viewer added one, else the library's address in its place.
   */
  leaveAddress() {
    const paths = this.addresses()
    const server = this.addressClosing
    const pushed = this.addressPushed
    const sameView = this.addressHistoryId !== null && this.addressHistoryId === window.history.state?.id
    this.addressClosing = false
    this.addressOpen = false
    this.addressPushed = false
    this.addressHistoryId = null
    if (!paths || server || !this.atPhotoAddress(paths)) return

    // After a tab reload, the library entry can still name the old LiveView.
    // Back would remount it and discard the grid. Patch the current view instead.
    if (pushed && sameView) window.history.back()
    else this.js().patch(paths.library, { replace: true })
  },

  /** The host says which photo its address names: `{ id, global }`, or `{ id: null }` for none. */
  applyView(payload) {
    if (!this.addresses()) return
    const { id, global, page } = payload || {}

    if (!id) {
      this.view = null
      if (this.pager && this.pager !== true) {
        this.addressClosing = true
        this.pager.close()
      }
      return
    }

    // Our own address change, coming back: the viewer is already there (or further on).
    const at = this.addressSent && this.addressSent.get(id)
    if (this.pager && at && Date.now() - at < ECHO_MS) return

    this.view = { id, global, page: Number.isInteger(page) ? page : 0 }
    this.openFromAddress()
  },

  /**
   * Open or turn the viewer to the photo the address names, once there is an index to place it
   * in, and that index is the server's current one (`sayHello`).
   */
  openFromAddress() {
    const view = this.view
    if (!view || !this.pagerEnabled() || !Number.isFinite(view.global) || !this.sections.length) return
    if (!this.indexCurrent) return
    if (this.pager === true) return
    this.view = null

    // A page of a stack is where its stack is; until the stack's pages are here the viewer
    // opens on its cover and follows on to the page when they arrive (`setStack`).
    const known = this.stacked().indexOf(view.id)
    const at = known >= 0 ? known : this.stacked().toView(view.global, view.page)
    if (known < 0 && view.page > 0) this.following = view.id

    if (this.pager) {
      const slide = this.stacked().get(this.pager.index)
      if (slide && slide.id === view.id) return
      if (this.pager.goTo) this.pager.goTo(at)
      return
    }

    // The address already names it: opening the viewer must not add another entry.
    this.addressOpen = true
    this.openPager(at)
  },

  thumbOf(id) {
    const node = this.pool.get(id)
    const img = node && node.querySelector("img")
    return img ? img.currentSrc || img.src : undefined
  },

  // The tile the viewer flies back to: a stack's page goes back to the stack's tile.
  tileImage(index) {
    const slide = this.slides.get(this.stacked().fromView(index).at)
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
    const rect = this.layoutOf(this.sections[found]).rect(index - this.sectionStarts[found])
    const top = this.offsets[found] + rect.y
    const view = this.el.clientHeight
    // The tile must clear the header the grid scrolls under.
    if (top < this.el.scrollTop + this.inset || top + rect.h > this.el.scrollTop + view) {
      this.el.scrollTop = Math.max(0, top - this.inset - (view - this.inset - rect.h) / 2)
      this.handleScroll()
    }
  },

  visibleItemRange(section) {
    const sectionIndex = this.sections.indexOf(section)
    if (sectionIndex < 0 || !section || section.count <= 0) return { first: 0, last: -1 }

    const top = this.offsets[sectionIndex]
    const viewTop = this.el.scrollTop
    return this.layoutOf(section).range(viewTop - top, viewTop + this.el.clientHeight - top)
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
      const layout = this.layoutOf(section)
      if (layout.calendar) {
        keep.add(`header:back:${section.id}`)
        keep.add(`header:front:${section.id}`)
        this.placeCalendar(section, sectionIndex, layout)
      }
      const { first, last } = this.visibleItemRange(section)
      for (let index = first; index <= last; index++) {
        const item = itemAt(section, index, this.windows)
        if (!item) continue
        const position = this.tilePosition(sectionIndex, index)
        // A photo the calendar has no room for has no size: it gets no tile.
        if (position.w <= 0 || position.h <= 0) continue
        keep.add(item.id)
        wanted.push({ item, global: this.sectionStarts[sectionIndex] + index, ...position })
      }
    }

    for (const [id, node] of this.pool) {
      if (!keep.has(id)) {
        // In a change of style a tile that leaves the screen goes there, not out of existence.
        if (this.leaving && !id.startsWith("header:")) this.leaving.set(id, node)
        else node.remove()
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
        ? "pkt-header pointer-events-none px-3 text-base font-semibold"
        : "pkt-header pointer-events-none px-1 text-sm font-semibold"
      node.append(document.createElement("span"))
      if (this.selectable()) {
        const check = document.createElement("button")
        check.type = "button"
        check.className = "pkt-section-check"
        check.dataset.sectionSelect = ""
        check.setAttribute("aria-label", this.root()?.dataset.selectMonthLabel || "Select month")
        // By id: a refresh replaces the section objects under a heading that stays on screen.
        check.addEventListener("click", () => this.selectSection(this.sections.findIndex(s => s.id === section.id)))
        node.append(check)
      }
      this.layer.appendChild(node)
      this.pool.set(id, node)
    }
    node.firstChild.textContent = section.label || section.id
    const top = this.offsets[sectionIndex]
    if (this.gliding) glide(node, 0, top)
    node.style.position = "absolute"
    node.style.left = "0"
    node.style.top = `${top}px`
    node.style.height = `${this.metrics.header}px`
    node.style.lineHeight = `${this.metrics.header}px`
  },

  /**
   * The calendar's weekdays, day squares and numbers for a month (calendar.js): one node behind
   * the tiles and one in front. Pooled as headers, so a change of style does not walk them.
   */
  placeCalendar(section, sectionIndex, layout) {
    const nodes = ["back", "front"].map(part => {
      const id = `header:${part}:${section.id}`
      let node = this.pool.get(id)
      if (!node) {
        node = document.createElement("div")
        node.className = `pkt-cal pkt-cal-${part}`
        node.setAttribute("aria-hidden", "true")
        this.layer.appendChild(node)
        this.pool.set(id, node)
      }
      node.style.top = `${this.offsets[sectionIndex]}px`
      node.style.height = `${layout.height}px`
      return node
    })
    if (nodes[0].pktLayout !== layout) {
      nodes[0].pktLayout = layout
      drawCalendar(nodes[0], nodes[1], layout, { lang: this.lang })
    }
  },

  tilePosition(sectionIndex, index) {
    const { x, y, w, h } = this.layoutOf(this.sections[sectionIndex]).rect(index)
    return { x, y: this.offsets[sectionIndex] + y, w, h }
  },

  placeTile({ item, x, y, w, h, global }) {
    let node = this.pool.get(item.id)
    const created = !node
    if (!node) {
      node = document.createElement("button")
      node.type = "button"
      node.dataset.fileId = item.id
      node.setAttribute("aria-label", item.kind === "video" ? "Open video" : "Open photo")
      node.className = "pkt-tile"
      node.addEventListener("pointerdown", () => this.prefetchSlides(Number(node.dataset.global)))
      node.addEventListener("click", (event) => this.tileClick(event, node, item.id))
      fillTile(node, item)
      this.layer.appendChild(node)
      this.pool.set(item.id, node)
    } else if (this.gliding && parseFloat(node.style.width) === w && parseFloat(node.style.height) === h) {
      // Only a move: a change of size (zoom, resize) is laid out, not animated.
      glide(node, x, y)
    }

    node.dataset.global = String(global)
    markPending(node, item)
    markStack(node, item, this.root()?.dataset.stackLabel)
    node.toggleAttribute("data-selected", this.isSelected(item.id))
    node.style.position = "absolute"
    node.style.left = `${x}px`
    node.style.top = `${y}px`
    node.style.width = `${w}px`
    node.style.height = `${h}px`

    const img = node.querySelector("img:last-of-type")
    const src = pickSource(item, w, h, this.style(), devicePixels())
    if (img && src && img.dataset.src !== src) {
      // A tile on screen keeps its picture until the better one is ready; so does one that
      // showed the uploader's picture while its own was being made.
      const old = img.dataset.src
      if (!created && old && (this.sharpening(old, item) || old.startsWith("blob:"))) swapImage(node, img, src)
      else {
        img.dataset.src = src
        img.src = src
      }
    } else if (img && !src) {
      img.removeAttribute("src")
      delete img.dataset.src
    }

    if (created && this.fresh.delete(item.id)) popIn(node)
  },

  /** Whether changing from `old` is a change of picture, not a link that ran out being renewed. */
  sharpening(old, item) {
    return [item.thumb, item.fit, item.preview, item.large].includes(old)
  },

  // --- styles: how the tiles look, and the walk from one look to another ---

  style() {
    return STYLES[this.styleId] || STYLES[DEFAULT_STYLE]
  },

  /** The styles the host offers: the person's choice stays within them. */
  offeredStyles() {
    return (this.el.dataset.styles || "").split(" ").filter(id => STYLES[id])
  },

  /** What the person picked last, else what the host asks for, else the plain grid. */
  startingStyle() {
    let stored = null
    try {
      stored = window.localStorage.getItem(STYLE_KEY)
    } catch (_error) {
      // private mode and the like
    }
    if (this.offeredStyles().includes(stored)) return stored
    const asked = this.el.dataset.style
    return STYLES[asked] ? asked : DEFAULT_STYLE
  },

  rememberStyle() {
    try {
      window.localStorage.setItem(STYLE_KEY, this.styleId)
    } catch (_error) {
      // the choice lasts until the page is left
    }
  },

  /** Tell the server on hello whether this style needs the aspect ratios with the index. */
  readyPayload() {
    return this.style().aspects ? { aspects: true } : {}
  },

  storeAspects(aspects) {
    if (!aspects) return
    this.aspects = this.aspects || new Map()
    for (const [id, bytes] of Object.entries(aspects)) this.aspects.set(id, decodeAspects(bytes))
    this.layouts = null
  },

  /**
   * The ratios arrived on their own: for a style waiting on them, or to replace averages. They
   * are kept whatever index they were made for: the server sends a month only once, and a month
   * that has changed since fails the length check and waits for its update.
   */
  setAspects({ aspects }) {
    this.storeAspects(aspects)
    clearTimeout(this.aspectsTimer)
    if (this.pendingStyle) {
      const id = this.pendingStyle
      this.pendingStyle = null
      this.morphTo(id)
    } else if (this.style().aspects) {
      this.relayout()
      this.handleScroll()
    }
  },

  hasAspects() {
    return this.sections.every(s => this.aspects?.get(s.id)?.length === s.count)
  },

  /** Whether this library is small enough for a style. */
  styleFits(id) {
    const limit = STYLES[id]?.maxFiles
    return !limit || this.sections.reduce((sum, section) => sum + section.count, 0) <= limit
  },

  /** Change style. One that shows whole photos first asks for the ratios it is placed by. */
  setStyle(id) {
    if (!STYLES[id] || !this.styleFits(id)) return
    this.pendingStyle = null
    clearTimeout(this.aspectsTimer)
    this.markStyle(id)
    this.toggleStyleMenu(false)
    if (id === this.styleId) return
    if (STYLES[id].aspects && !this.hasAspects()) {
      this.pendingStyle = id
      this.send("timeline:aspects", { revision: this.revision })
      this.aspectsTimer = setTimeout(() => {
        const waiting = this.pendingStyle
        this.pendingStyle = null
        if (waiting) this.morphTo(waiting)
      }, ASPECTS_WAIT_MS)
      return
    }
    this.morphTo(id)
  },

  /**
   * Walk the tiles from this style to `id`: the photo in the middle of the screen stays there,
   * and every tile goes from where it was to where it belongs (see morph.js).
   */
  morphTo(id) {
    const height = this.el.clientHeight
    const focus = this.sections.length ? this.itemAtPoint(this.el.clientWidth / 2, height / 2) : null
    const spot = focus ? this.tileMiddle(focus) - this.el.scrollTop : height / 2
    const before = this.geometry()
    const from = new Map()
    for (const [key, node] of this.pool) {
      if (!key.startsWith("header:")) from.set(key, rectOf(node))
    }

    this.styleId = id
    this.el.dataset.activeStyle = id
    this.rememberStyle()
    this.beginPositionInput({ type: "wheel" })
    this.relayout(null)
    if (focus) this.el.scrollTop = Math.max(0, this.tileMiddle(focus) - spot)

    this.leaving = new Map()
    this.handleScroll()
    const leaving = this.leaving
    this.leaving = null

    morph({
      layer: this.layer,
      tiles: this.pool,
      from,
      leaving,
      shift: this.el.scrollTop - before.scrollTop,
      viewport: { top: this.el.scrollTop, height },
      focusY: this.el.scrollTop + spot,
      focusX: this.el.clientWidth / 2,
      previousRect: (global) => this.rectIn(before, global),
      nextRect: (global) => this.rectIn(this.geometry(), global)
    })
  },

  /** What it takes to place a tile in the style on screen, for when the style has changed. */
  geometry() {
    const layouts = this.sections.map(section => this.layoutOf(section))
    return { layouts, offsets: this.offsets, starts: this.sectionStarts, scrollTop: this.el.scrollTop }
  },

  /** Where the file at position `global` of the library goes in a `geometry()`. */
  rectIn({ layouts, offsets, starts }, global) {
    let found = -1
    for (let i = 0; i < starts.length && starts[i] <= global; i++) found = i
    if (found < 0 || !layouts[found] || global - starts[found] >= layouts[found].count) return null
    const rect = layouts[found].rect(global - starts[found])
    return { ...rect, y: offsets[found] + rect.y }
  },

  /** Show which style is on, in the component's menu. */
  markStyle(id) {
    const root = this.el.closest?.(".phoenix-kit-photo-timeline")
    if (!root) return
    for (const button of root.querySelectorAll("[data-style-pick]")) {
      button.setAttribute("aria-pressed", String(button.dataset.stylePick === id))
      button.disabled = !this.styleFits(button.dataset.stylePick)
    }
    const icon = root.querySelector("[data-style-current]")
    const picked = root.querySelector(`[data-style-pick="${id}"] svg`)
    if (icon && picked) icon.replaceChildren(picked.cloneNode(true))
  },

  styleMenuOpen() {
    const menu = this.el.closest?.(".phoenix-kit-photo-timeline")?.querySelector("[data-style-menu]")
    return Boolean(menu && !menu.hidden)
  },

  toggleStyleMenu(open) {
    const root = this.el.closest?.(".phoenix-kit-photo-timeline")
    const menu = root?.querySelector("[data-style-menu]")
    const toggle = root?.querySelector("[data-style-toggle]")
    if (!menu || !toggle) return
    const show = open ?? menu.hidden
    menu.hidden = !show
    toggle.setAttribute("aria-expanded", String(show))
  },

  /** The menu is the component's markup; every click on it is handled here, in the browser. */
  bindStyleMenu() {
    const root = this.el.closest?.(".phoenix-kit-photo-timeline")
    if (!root) return
    this.onStyleClick = (event) => {
      const pick = event.target.closest?.("[data-style-pick]")
      if (pick) {
        this.setStyle(pick.dataset.stylePick)
        // The picked button is hidden with the menu: focus goes back to what opened it.
        root.querySelector("[data-style-toggle]")?.focus?.()
      } else if (event.target.closest?.("[data-style-toggle]")) {
        this.toggleStyleMenu()
      } else if (!event.target.closest?.("[data-style-menu]")) {
        this.toggleStyleMenu(false)
      }
    }
    this.onStyleKey = (event) => this.styleKey(event)
    document.addEventListener("click", this.onStyleClick)
    window.addEventListener("keydown", this.onStyleKey)
    this.markStyle(this.styleId)
  },

  unbindStyleMenu() {
    if (this.onStyleClick) document.removeEventListener("click", this.onStyleClick)
    if (this.onStyleKey) window.removeEventListener("keydown", this.onStyleKey)
  },

  /** `v` walks through the styles, Shift+`v` back, and Escape closes the menu. */
  styleKey(event) {
    if (event.key === "Escape" && this.styleMenuOpen()) {
      // Escape closes the menu and does nothing else: the selection stays.
      this.toggleStyleMenu(false)
      event.preventDefault()
      return
    }
    if (this.pager || event.metaKey || event.ctrlKey || event.altKey) return
    if (event.key !== "v" && event.key !== "V") return
    const target = event.target
    if (target && (/^(input|select|textarea)$/i.test(target.tagName || "") || target.isContentEditable)) return
    const offered = this.offeredStyles()
    if (offered.length < 2) return
    const step = event.shiftKey ? -1 : 1
    const at = offered.indexOf(this.pendingStyle || this.styleId)
    this.setStyle(offered[(at + step + offered.length) % offered.length])
    event.preventDefault()
  }
}

/** Where a tile is on the layer now, from its own inline style. */
function rectOf(node) {
  return {
    x: parseFloat(node.style.left) || 0,
    y: parseFloat(node.style.top) || 0,
    w: parseFloat(node.style.width) || 0,
    h: parseFloat(node.style.height) || 0
  }
}

function devicePixels() {
  return typeof window !== "undefined" ? Math.min(2, window.devicePixelRatio || 1) : 1
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
