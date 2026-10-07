var PhoenixKitPhotosHooks = (() => {
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

  // js/viewer_warm.js
  var LARGE_RUNG_PX = 1920;
  var HEADROOM = 1.1;
  function constrained(connection) {
    if (!connection) return false;
    return Boolean(connection.saveData) || /(^|-)[23]g$/.test(connection.effectiveType || "");
  }
  function parseAspect(aspect) {
    if (typeof aspect === "number") return aspect > 0 ? aspect : null;
    const m = /^\s*([\d.]+)\s*(?:\/\s*([\d.]+))?\s*$/.exec(aspect || "");
    if (!m) return null;
    const ratio = m[2] === void 0 ? Number(m[1]) : Number(m[1]) / Number(m[2]);
    return Number.isFinite(ratio) && ratio > 0 ? ratio : null;
  }
  function displayedPx(aspect, box) {
    if (!box) return 0;
    const width = box.width || 0;
    const height = box.height || 0;
    const ratio = parseAspect(aspect);
    const css = ratio && height > 0 ? Math.min(width, height * ratio) : width;
    return css * (box.dpr || 1);
  }
  function originalsToWarm(detail, connection) {
    if (!detail || constrained(connection)) return [];
    const side = detail.direction === "prev" ? detail.prev : detail.next;
    if (!side || typeof side.original !== "string" || side.original === "") return [];
    if (!(displayedPx(side.aspect, detail.box) > LARGE_RUNG_PX * HEADROOM)) return [];
    return [side.original];
  }
  function installViewerWarm(win, ImageCtor) {
    if (!win || typeof win.addEventListener !== "function") return null;
    const Img = ImageCtor || win.Image;
    const listener = (e) => {
      const connection = win.navigator && win.navigator.connection;
      win.__pkWarmedUrls = win.__pkWarmedUrls || {};
      for (const url of originalsToWarm(e && e.detail, connection)) {
        if (win.__pkWarmedUrls[url]) continue;
        win.__pkWarmedUrls[url] = true;
        const im = new Img();
        try {
          im.fetchPriority = "low";
        } catch (_e) {
        }
        im.src = url;
      }
    };
    win.addEventListener("pk:viewer-neighbours", listener);
    return listener;
  }

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

  // js/photo_timeline.js
  var DEFAULTS = { cell: 160, gap: 4, header: 40 };
  var PhotoTimeline = {
    mounted() {
      this.columns = Math.max(1, parseInt(this.el.dataset.columns || "5", 10) || 5);
      this.metrics = { ...DEFAULTS };
      this.sections = [];
      this.offsets = [0];
      this.windows = /* @__PURE__ */ new Map();
      this.pool = /* @__PURE__ */ new Map();
      this.library = null;
      this.revision = null;
      this.needed = /* @__PURE__ */ new Set();
      this.spacer = this.el.querySelector(".phoenix-kit-photo-timeline__spacer");
      this.layer = this.el.querySelector(".phoenix-kit-photo-timeline__layer");
      this.onScroll = throttleToFrame(() => this.handleScroll());
      this.el.addEventListener("scroll", this.onScroll, { passive: true });
      this.onResize = debounce(() => this.handleResize(), 120);
      window.addEventListener("resize", this.onResize);
      this.resizeObserver = new ResizeObserver(this.onResize);
      this.resizeObserver.observe(this.el);
      const prefix = `timeline:${this.el.dataset.timelineId}`;
      this.handleEvent(`${prefix}:index`, (payload) => this.setIndex(payload));
      this.handleEvent(`${prefix}:window`, (payload) => this.setWindow(payload));
      this.handleEvent(`${prefix}:jump`, ({ id }) => this.jumpTo(id));
      this.send("timeline:ready", {});
    },
    send(event, payload) {
      this.pushEventTo(Number(this.el.dataset.target), event, payload);
    },
    reconnected() {
      this.send("timeline:ready", {});
    },
    destroyed() {
      this.el.removeEventListener("scroll", this.onScroll);
      window.removeEventListener("resize", this.onResize);
      this.resizeObserver.disconnect();
      this.onResize.cancel();
      this.onScroll.cancel();
      this.pool.clear();
    },
    setIndex(payload) {
      const libraryChanged = payload.library !== this.library;
      const anchor = libraryChanged ? null : this.captureAnchor();
      this.library = payload.library;
      if (payload.revision === this.revision && !libraryChanged) return;
      this.revision = payload.revision;
      this.windows.clear();
      this.sections = payload.sections || [];
      if (payload.metrics) this.metrics = { ...this.metrics, ...payload.metrics };
      this.relayout(anchor);
      if (libraryChanged) {
        const height = totalHeight(this.offsets);
        this.el.scrollTop = Math.max(0, height - this.el.clientHeight);
      }
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
     * changed height too, so a per-section correction leaves the user
     * somewhere else in their history.
     */
    captureAnchor() {
      const anchor = anchorAt(this.offsets, this.el.scrollTop);
      if (!anchor) return null;
      return {
        id: this.sections[anchor.index]?.id,
        index: anchor.index,
        headerOffset: Math.min(anchor.delta, this.metrics.header),
        row: Math.max(0, anchor.delta - this.metrics.header) / (this.metrics.cell + this.metrics.gap)
      };
    },
    relayout(anchor = this.captureAnchor()) {
      if (this.el.clientWidth > 0) {
        this.metrics.cell = Math.max(1, (this.el.clientWidth - (this.columns - 1) * this.metrics.gap) / this.columns);
      }
      this.offsets = buildOffsets(this.sections, (s) => this.measure(s));
      if (this.spacer) this.spacer.style.height = `${totalHeight(this.offsets)}px`;
      if (anchor && this.sections.length) {
        const found = this.sections.findIndex((s) => s.id === anchor.id);
        const index = found >= 0 ? found : Math.min(anchor.index, this.sections.length - 1);
        const delta = found >= 0 ? anchor.headerOffset + anchor.row * (this.metrics.cell + this.metrics.gap) : 0;
        this.el.scrollTop = this.offsets[index] + delta;
      }
    },
    handleResize() {
      this.relayout();
      this.handleScroll();
    },
    handleScroll() {
      const indices = visibleSections(this.offsets, this.el.scrollTop, this.el.clientHeight);
      this.needed = /* @__PURE__ */ new Set();
      for (const i of indices) this.ensureVisibleDays(this.sections[i]);
      for (const day of this.windows.keys()) {
        if (!this.needed.has(day)) this.windows.delete(day);
      }
      this.materialize(indices);
    },
    /**
     * Request the days of a section that intersect the viewport, plus the
     * neighbouring day, so a jump does not land on an empty month.
     *
     * Windows are days, never months.
     */
    ensureVisibleDays(section) {
      if (!section) return;
      const days = section.days_list || [];
      const needed = /* @__PURE__ */ new Set();
      const { first, last } = this.visibleItemRange(section);
      for (let index = first; index <= last; index++) {
        const dayIndex = dayIndexFor(days, index);
        if (dayIndex < 0) continue;
        needed.add(dayIndex);
        if (dayIndex > 0) needed.add(dayIndex - 1);
        if (dayIndex + 1 < days.length) needed.add(dayIndex + 1);
      }
      for (const dayIndex of needed) this.requestDay(days[dayIndex].id);
    },
    requestDay(day) {
      if (!day) return;
      this.needed.add(day);
      if (this.windows.has(day)) return;
      this.windows.set(day, null);
      this.send("timeline:need_window", { window: day, revision: this.revision });
    },
    setWindow({ section, items, revision }) {
      if (revision !== this.revision || !this.windows.has(section)) return;
      this.windows.set(section, items || []);
      this.handleScroll();
    },
    /** Jump to a section id, e.g. "2018-07". */
    jumpTo(sectionId) {
      const index = this.sections.findIndex((s) => s.id === sectionId);
      if (index >= 0) {
        this.el.scrollTop = this.offsets[index];
        this.handleScroll();
      }
    },
    visibleItemRange(section) {
      const sectionIndex = this.sections.indexOf(section);
      if (sectionIndex < 0 || !section || section.count <= 0) return { first: 0, last: -1 };
      const { cell, gap, header } = this.metrics;
      const stride = cell + gap;
      const contentTop = this.offsets[sectionIndex] + header;
      const viewTop = this.el.scrollTop;
      const viewBottom = viewTop + this.el.clientHeight;
      const firstRow = Math.max(0, Math.floor((viewTop - contentTop) / stride) - 1);
      const lastRow = Math.ceil((viewBottom - contentTop) / stride) + 1;
      const lastIndex = Math.max(0, section.count - 1);
      if (lastRow < 0 || firstRow * this.columns > lastIndex) return { first: 0, last: -1 };
      return {
        first: Math.min(lastIndex, firstRow * this.columns),
        last: Math.min(lastIndex, (lastRow + 1) * this.columns - 1)
      };
    },
    materialize(sectionIndices) {
      if (!this.layer) return;
      const wanted = [];
      const keep = /* @__PURE__ */ new Set();
      for (const sectionIndex of sectionIndices) {
        const section = this.sections[sectionIndex];
        if (!section) continue;
        keep.add(`header:${section.id}`);
        this.placeHeader(section, sectionIndex);
        const { first, last } = this.visibleItemRange(section);
        for (let index = first; index <= last; index++) {
          const item = itemAt(section, index, this.windows);
          if (!item) continue;
          keep.add(item.id);
          wanted.push({ item, ...this.tilePosition(sectionIndex, index) });
        }
      }
      for (const [id, node] of this.pool) {
        if (!keep.has(id)) {
          node.remove();
          this.pool.delete(id);
        }
      }
      for (const entry of wanted) this.placeTile(entry);
    },
    placeHeader(section, sectionIndex) {
      const id = `header:${section.id}`;
      let node = this.pool.get(id);
      if (!node) {
        node = document.createElement("div");
        node.className = "pointer-events-none px-1 text-sm font-semibold";
        this.layer.appendChild(node);
        this.pool.set(id, node);
      }
      node.textContent = section.label || section.id;
      node.style.position = "absolute";
      node.style.left = "0";
      node.style.top = `${this.offsets[sectionIndex]}px`;
      node.style.height = `${this.metrics.header}px`;
      node.style.lineHeight = `${this.metrics.header}px`;
    },
    tilePosition(sectionIndex, index) {
      const { cell, gap, header } = this.metrics;
      const col = index % this.columns;
      const row = Math.floor(index / this.columns);
      return {
        x: col * (cell + gap),
        y: this.offsets[sectionIndex] + header + row * (cell + gap),
        size: cell
      };
    },
    placeTile({ item, x, y, size }) {
      let node = this.pool.get(item.id);
      if (!node) {
        node = document.createElement("button");
        node.type = "button";
        node.dataset.fileId = item.id;
        node.setAttribute("aria-label", item.kind === "video" ? "Open video" : "Open photo");
        node.className = "pointer-events-auto overflow-hidden bg-base-200 p-0";
        node.addEventListener("click", () => {
          this.send("timeline:open", { id: item.id });
        });
        const img2 = document.createElement("img");
        img2.alt = "";
        img2.loading = "lazy";
        img2.decoding = "async";
        img2.draggable = false;
        img2.style.width = "100%";
        img2.style.height = "100%";
        img2.style.objectFit = "cover";
        node.appendChild(img2);
        this.layer.appendChild(node);
        this.pool.set(item.id, node);
      }
      node.style.position = "absolute";
      node.style.left = `${x}px`;
      node.style.top = `${y}px`;
      node.style.width = `${size}px`;
      node.style.height = `${size}px`;
      const img = node.querySelector("img");
      const src = item.thumb || item.preview;
      if (img && src && img.dataset.src !== src) {
        img.dataset.src = src;
        img.src = src;
      } else if (img && !src) {
        img.removeAttribute("src");
        delete img.dataset.src;
      }
    }
  };
  function dayIndexFor(days, itemIndex) {
    let cursor = 0;
    for (let i = 0; i < days.length; i++) {
      const count = days[i].count || 0;
      if (itemIndex < cursor + count) return i;
      cursor += count;
    }
    return -1;
  }
  function itemAt(section, itemIndex, windows) {
    const days = section.days_list || [];
    let cursor = 0;
    for (const day of days) {
      const count = day.count || 0;
      if (itemIndex < cursor + count) {
        const items = windows.get(day.id);
        if (!items) return null;
        return items[itemIndex - cursor] || null;
      }
      cursor += count;
    }
    return null;
  }
  function throttleToFrame(fn) {
    let scheduled = null;
    const callback = () => {
      if (scheduled !== null) return;
      scheduled = requestAnimationFrame(() => {
        scheduled = null;
        fn();
      });
    };
    callback.cancel = () => {
      if (scheduled !== null) cancelAnimationFrame(scheduled);
      scheduled = null;
    };
    return callback;
  }
  function debounce(fn, ms) {
    let timer = null;
    const callback = () => {
      clearTimeout(timer);
      timer = setTimeout(fn, ms);
    };
    callback.cancel = () => clearTimeout(timer);
    return callback;
  }

  // js/index.js
  if (typeof window !== "undefined") installViewerWarm(window);
  return __toCommonJS(index_exports);
})();
window.PhoenixKitPhotosHooks=PhoenixKitPhotosHooks;
