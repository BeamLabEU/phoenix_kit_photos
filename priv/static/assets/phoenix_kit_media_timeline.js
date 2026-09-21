var PhoenixKitMediaTimelineHooks = (() => {
  var __defProp = Object.defineProperty;
  var __getOwnPropDesc = Object.getOwnPropertyDescriptor;
  var __getOwnPropNames = Object.getOwnPropertyNames;
  var __hasOwnProp = Object.prototype.hasOwnProperty;
  var __export = (target, all) => {
    for (var name in all)
      __defProp(target, name, { get: all[name], enumerable: true });
  };
  var __copyProps = (to, from, except, desc) => {
    if (from && typeof from === "object" || typeof from === "function") {
      for (let key of __getOwnPropNames(from))
        if (!__hasOwnProp.call(to, key) && key !== except)
          __defProp(to, key, { get: () => from[key], enumerable: !(desc = __getOwnPropDesc(from, key)) || desc.enumerable });
    }
    return to;
  };
  var __toCommonJS = (mod) => __copyProps(__defProp({}, "__esModule", { value: true }), mod);

  // js/index.js
  var index_exports = {};
  __export(index_exports, {
    PhotoTimeline: () => PhotoTimeline
  });

  // js/geometry.js
  function squareSectionHeight({ count, columns, cell, gap, header }) {
    if (count <= 0) return header;
    const rows = Math.ceil(count / columns);
    return header + rows * cell + (rows - 1) * gap;
  }
  function buildOffsets(sections, measure) {
    const offsets = new Array(sections.length + 1);
    let acc = 0;
    for (let i = 0; i < sections.length; i++) {
      offsets[i] = acc;
      acc += measure(sections[i], i);
    }
    offsets[sections.length] = acc;
    return offsets;
  }
  function totalHeight(offsets) {
    return offsets.length ? offsets[offsets.length - 1] : 0;
  }
  function sectionAtOffset(offsets, y) {
    const last = offsets.length - 2;
    if (last < 0) return -1;
    if (y <= 0) return 0;
    if (y >= offsets[last + 1]) return last;
    let lo = 0;
    let hi = last;
    while (lo < hi) {
      const mid = lo + hi + 1 >> 1;
      if (offsets[mid] <= y) lo = mid;
      else hi = mid - 1;
    }
    return lo;
  }
  function visibleSections(offsets, scrollTop, viewportHeight, buffer = 1) {
    const last = offsets.length - 2;
    if (last < 0) return [];
    const first = sectionAtOffset(offsets, scrollTop);
    const lastVisible = sectionAtOffset(offsets, scrollTop + viewportHeight);
    const from = Math.max(0, first - buffer);
    const to = Math.min(last, lastVisible + buffer);
    const out = [];
    for (let i = from; i <= to; i++) out.push(i);
    return out;
  }
  function anchorAt(offsets, scrollTop) {
    const index = sectionAtOffset(offsets, scrollTop);
    if (index < 0) return null;
    return { index, delta: scrollTop - offsets[index] };
  }
  function offsetForAnchor(offsets, anchor) {
    if (!anchor || anchor.index < 0 || anchor.index >= offsets.length - 1) return 0;
    return offsets[anchor.index] + anchor.delta;
  }

  // js/photo_timeline.js
  var DEFAULTS = { cell: 160, gap: 4, header: 40 };
  var PhotoTimeline = {
    mounted() {
      this.columns = parseInt(this.el.dataset.columns || "5", 10);
      this.metrics = { ...DEFAULTS };
      this.sections = [];
      this.offsets = [0];
      this.windows = /* @__PURE__ */ new Map();
      this.spacer = this.el.querySelector(".phoenix-kit-media-timeline__spacer");
      this.onScroll = throttleToFrame(() => this.handleScroll());
      this.el.addEventListener("scroll", this.onScroll, { passive: true });
      this.onResize = debounce(() => this.handleResize(), 120);
      window.addEventListener("resize", this.onResize);
      this.handleEvent("timeline:index", (payload) => this.setIndex(payload));
      this.handleEvent("timeline:window", (payload) => this.setWindow(payload));
    },
    destroyed() {
      this.el.removeEventListener("scroll", this.onScroll);
      window.removeEventListener("resize", this.onResize);
    },
    // --- index -------------------------------------------------------------
    setIndex({ sections, metrics }) {
      this.sections = sections || [];
      if (metrics) this.metrics = { ...this.metrics, ...metrics };
      this.relayout();
      this.handleScroll();
    },
    measure(section) {
      const { cell, gap, header } = this.metrics;
      return squareSectionHeight({
        count: section.count,
        columns: this.columns,
        cell,
        gap,
        header
      });
    },
    /**
     * Rebuild every offset and restore position by anchor item.
     *
     * Not by scrollTop delta: on a resize every section above the viewport
     * changed height too, so a per-section correction leaves the user somewhere
     * else in their history.
     */
    relayout() {
      const anchor = this.offsets.length > 1 ? anchorAt(this.offsets, this.el.scrollTop) : null;
      this.offsets = buildOffsets(this.sections, (s) => this.measure(s));
      if (this.spacer) this.spacer.style.height = `${totalHeight(this.offsets)}px`;
      if (anchor) this.el.scrollTop = offsetForAnchor(this.offsets, anchor);
    },
    handleResize() {
      this.relayout();
      this.handleScroll();
    },
    // --- windows -----------------------------------------------------------
    handleScroll() {
      const indices = visibleSections(this.offsets, this.el.scrollTop, this.el.clientHeight);
      for (const i of indices) this.ensureWindows(this.sections[i]);
    },
    /**
     * Request the days of a section that are not yet loaded.
     *
     * Windows are days, never months: a holiday month of 20k items is ~5MB over
     * the socket, while a day is tens to a few hundred tiles.
     */
    ensureWindows(section) {
      if (!section) return;
      for (const day of section.days_list || []) {
        if (this.windows.has(day)) continue;
        this.windows.set(day, null);
        this.pushEvent("timeline:need_window", { window: day });
      }
    },
    setWindow({ section, items }) {
      this.windows.set(section, items);
    },
    // --- jump --------------------------------------------------------------
    /** Jump to a section id, e.g. "2018-07". */
    jumpTo(sectionId) {
      const index = this.sections.findIndex((s) => s.id === sectionId);
      if (index >= 0) this.el.scrollTop = this.offsets[index];
    }
  };
  function throttleToFrame(fn) {
    let scheduled = false;
    return () => {
      if (scheduled) return;
      scheduled = true;
      requestAnimationFrame(() => {
        scheduled = false;
        fn();
      });
    };
  }
  function debounce(fn, ms) {
    let timer = null;
    return () => {
      clearTimeout(timer);
      timer = setTimeout(fn, ms);
    };
  }
  return __toCommonJS(index_exports);
})();
window.PhoenixKitMediaTimelineHooks=PhoenixKitMediaTimelineHooks;
