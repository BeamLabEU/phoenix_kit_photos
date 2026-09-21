import {
  squareSectionHeight,
  buildOffsets,
  totalHeight,
  visibleSections,
  anchorAt,
  offsetForAnchor
} from "./geometry"

// Defaults; the server may override them through the index payload.
const DEFAULTS = { cell: 160, gap: 4, header: 40 }

/**
 * The timeline hook.
 *
 * Division of labour, per the plan: LiveView owns permissions, window
 * transport and PubSub; this hook owns geometry, tile recycling and the
 * scrubber. Nothing here knows about Elixir, Ecto or PhoenixKit — the contract
 * is two JSON shapes, `timeline:index` and `timeline:window`.
 *
 * The hook name must stay globally unique. The :phoenix_kit_js_sources
 * compiler folds every bundle's global into window.PhoenixKitHooks with
 * Object.assign, which is last-write-wins on hook names and cannot see inside
 * a prebuilt bundle. `PhotoTimeline`, never `Grid`.
 */
export const PhotoTimeline = {
  mounted() {
    this.columns = parseInt(this.el.dataset.columns || "5", 10)
    this.metrics = { ...DEFAULTS }
    this.sections = []
    this.offsets = [0]
    this.windows = new Map()

    this.spacer = this.el.querySelector(".phoenix-kit-photo-timeline__spacer")

    this.onScroll = throttleToFrame(() => this.handleScroll())
    this.el.addEventListener("scroll", this.onScroll, { passive: true })

    this.onResize = debounce(() => this.handleResize(), 120)
    window.addEventListener("resize", this.onResize)

    this.handleEvent("timeline:index", (payload) => this.setIndex(payload))
    this.handleEvent("timeline:window", (payload) => this.setWindow(payload))
  },

  destroyed() {
    this.el.removeEventListener("scroll", this.onScroll)
    window.removeEventListener("resize", this.onResize)
  },

  // --- index -------------------------------------------------------------

  setIndex({ sections, metrics }) {
    this.sections = sections || []
    if (metrics) this.metrics = { ...this.metrics, ...metrics }
    this.relayout()
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
   * changed height too, so a per-section correction leaves the user somewhere
   * else in their history.
   */
  relayout() {
    const anchor = this.offsets.length > 1 ? anchorAt(this.offsets, this.el.scrollTop) : null
    this.offsets = buildOffsets(this.sections, (s) => this.measure(s))
    if (this.spacer) this.spacer.style.height = `${totalHeight(this.offsets)}px`
    if (anchor) this.el.scrollTop = offsetForAnchor(this.offsets, anchor)
  },

  handleResize() {
    this.relayout()
    this.handleScroll()
  },

  // --- windows -----------------------------------------------------------

  handleScroll() {
    const indices = visibleSections(this.offsets, this.el.scrollTop, this.el.clientHeight)
    for (const i of indices) this.ensureWindows(this.sections[i])
    // TODO(Stage 1): materialize tiles for `indices` from the recycling pool,
    // and return the nodes of sections that left the buffer.
  },

  /**
   * Request the days of a section that are not yet loaded.
   *
   * Windows are days, never months: a holiday month of 20k items is ~5MB over
   * the socket, while a day is tens to a few hundred tiles.
   */
  ensureWindows(section) {
    if (!section) return
    for (const day of section.days_list || []) {
      if (this.windows.has(day)) continue
      this.windows.set(day, null)
      this.pushEvent("timeline:need_window", { window: day })
    }
  },

  setWindow({ section, items }) {
    this.windows.set(section, items)
    // TODO(Stage 1): place tiles for this day if its section is materialized.
  },

  // --- jump --------------------------------------------------------------

  /** Jump to a section id, e.g. "2018-07". */
  jumpTo(sectionId) {
    const index = this.sections.findIndex((s) => s.id === sectionId)
    if (index >= 0) this.el.scrollTop = this.offsets[index]
  }
}

function throttleToFrame(fn) {
  let scheduled = false
  return () => {
    if (scheduled) return
    scheduled = true
    requestAnimationFrame(() => {
      scheduled = false
      fn()
    })
  }
}

function debounce(fn, ms) {
  let timer = null
  return () => {
    clearTimeout(timer)
    timer = setTimeout(fn, ms)
  }
}
