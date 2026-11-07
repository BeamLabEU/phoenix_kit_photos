var PhoenixKitPhotosHooks = (() => {
  var __defProp = Object.defineProperty;
  var __getOwnPropDesc = Object.getOwnPropertyDescriptor;
  var __getOwnPropNames = Object.getOwnPropertyNames;
  var __hasOwnProp = Object.prototype.hasOwnProperty;
  var __defNormalProp = (obj, key, value) => key in obj ? __defProp(obj, key, { enumerable: true, configurable: true, writable: true, value }) : obj[key] = value;
  var __esm = (fn, res, err) => function __init() {
    if (err) throw err[0];
    try {
      return fn && (res = (0, fn[__getOwnPropNames(fn)[0]])(fn = 0)), res;
    } catch (e) {
      throw err = [e], e;
    }
  };
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
  var __publicField = (obj, key, value) => __defNormalProp(obj, typeof key !== "symbol" ? key + "" : key, value);

  // js/slides.js
  function flattenDays(sections) {
    const days = [];
    let start = 0;
    for (const section of sections || []) {
      for (const day of section.days_list || []) {
        const count = day.count || 0;
        if (count <= 0) continue;
        days.push({ id: day.id, count, start });
        start += count;
      }
    }
    return { days, total: start };
  }
  function locate(days, index) {
    let low = 0;
    let high = days.length - 1;
    while (low <= high) {
      const mid = low + high >> 1;
      const day = days[mid];
      if (index < day.start) high = mid - 1;
      else if (index >= day.start + day.count) low = mid + 1;
      else return { day, position: index - day.start };
    }
    return null;
  }
  function blocksAround(days, total, center, radius) {
    const blocks = /* @__PURE__ */ new Map();
    const first = Math.max(0, center - radius);
    const last = Math.min(total - 1, center + radius);
    for (let index = first; index <= last; index++) {
      const found = locate(days, index);
      if (!found) continue;
      const from = found.position - found.position % BLOCK;
      const key = `${found.day.id}@${from}`;
      if (!blocks.has(key)) {
        blocks.set(key, {
          key,
          window: found.day.id,
          from,
          count: BLOCK,
          start: found.day.start + from
        });
      }
    }
    return [...blocks.values()];
  }
  function wantWidth(view) {
    const ratio = view.devicePixelRatio || 1;
    return Math.max(400, Math.min(4096, Math.round(view.innerWidth * ratio)));
  }
  function chooseSource(sources, env) {
    const list = sources || [];
    const original = list.find((s) => s.role === "original");
    const rendition = list.find((s) => s.role === "rendition");
    if (original && env.hdrScreen && env.canPlay(original.type)) return original;
    return rendition || original || null;
  }
  var BLOCK, SlideStore;
  var init_slides = __esm({
    "js/slides.js"() {
      BLOCK = 12;
      SlideStore = class {
        constructor(sections) {
          const { days, total } = flattenDays(sections);
          this.days = days;
          this.total = total;
          this.slides = /* @__PURE__ */ new Map();
          this.asked = /* @__PURE__ */ new Set();
          this.byId = /* @__PURE__ */ new Map();
        }
        has(index) {
          return this.slides.has(index);
        }
        get(index) {
          return this.slides.get(index) || null;
        }
        indexOf(id) {
          return this.byId.has(id) ? this.byId.get(id) : -1;
        }
        /** Blocks around `center` that are neither here nor already asked for. */
        missing(center, radius) {
          return blocksAround(this.days, this.total, center, radius).filter(
            (block) => !this.asked.has(block.key) && !this.knowsBlock(block)
          );
        }
        knowsBlock(block) {
          const last = Math.min(block.start + block.count - 1, this.total - 1);
          for (let index = block.start; index <= last; index++) {
            if (!this.slides.has(index)) return false;
          }
          return true;
        }
        markAsked(block) {
          this.asked.add(block.key);
        }
        /** Forget that a block was asked for (the answer was an error), so it can be asked again. */
        forget(window2, from) {
          this.asked.delete(`${window2}@${from}`);
        }
        /** Files `items`, which started at `from` in the day `window`; the indices that were not known before. */
        put(window2, from, items) {
          const day = this.days.find((d) => d.id === window2);
          if (!day) return [];
          const added = [];
          items.forEach((item, offset) => {
            const index = day.start + from + offset;
            if (index >= this.total) return;
            if (!this.slides.has(index)) added.push(index);
            this.slides.set(index, item);
            this.byId.set(item.id, index);
          });
          return added;
        }
      };
    }
  });

  // js/viewer/engine.js
  function registerEngine(id, load) {
    engines.set(id, load);
  }
  function engineFor(setting) {
    const value = String(setting ?? "").trim();
    if (value === "" || value === "false") return null;
    if (value === "true") return DEFAULT_ENGINE;
    if (engines.has(value)) return value;
    return DEFAULT_ENGINE;
  }
  async function loadEngine(id) {
    const load = engines.get(id) || engines.get(DEFAULT_ENGINE);
    return load();
  }
  function dialogOpen() {
    try {
      return document.querySelector("dialog:modal") !== null;
    } catch (_error) {
      return false;
    }
  }
  var engines, DEFAULT_ENGINE;
  var init_engine = __esm({
    "js/viewer/engine.js"() {
      engines = /* @__PURE__ */ new Map();
      DEFAULT_ENGINE = "photoswipe";
    }
  });

  // ../../phoenix_kit_photos/assets/node_modules/photoswipe/dist/photoswipe.esm.js
  function createElement(className, tagName, appendToEl) {
    const el = document.createElement(tagName);
    if (className) {
      el.className = className;
    }
    if (appendToEl) {
      appendToEl.appendChild(el);
    }
    return el;
  }
  function equalizePoints(p1, p2) {
    p1.x = p2.x;
    p1.y = p2.y;
    if (p2.id !== void 0) {
      p1.id = p2.id;
    }
    return p1;
  }
  function roundPoint(p) {
    p.x = Math.round(p.x);
    p.y = Math.round(p.y);
  }
  function getDistanceBetween(p1, p2) {
    const x = Math.abs(p1.x - p2.x);
    const y = Math.abs(p1.y - p2.y);
    return Math.sqrt(x * x + y * y);
  }
  function pointsEqual(p1, p2) {
    return p1.x === p2.x && p1.y === p2.y;
  }
  function clamp(val, min, max) {
    return Math.min(Math.max(val, min), max);
  }
  function toTransformString(x, y, scale) {
    let propValue = `translate3d(${x}px,${y || 0}px,0)`;
    if (scale !== void 0) {
      propValue += ` scale3d(${scale},${scale},1)`;
    }
    return propValue;
  }
  function setTransform(el, x, y, scale) {
    el.style.transform = toTransformString(x, y, scale);
  }
  function setTransitionStyle(el, prop, duration, ease) {
    el.style.transition = prop ? `${prop} ${duration}ms ${ease || defaultCSSEasing}` : "none";
  }
  function setWidthHeight(el, w, h) {
    el.style.width = typeof w === "number" ? `${w}px` : w;
    el.style.height = typeof h === "number" ? `${h}px` : h;
  }
  function removeTransitionStyle(el) {
    setTransitionStyle(el);
  }
  function decodeImage(img) {
    if ("decode" in img) {
      return img.decode().catch(() => {
      });
    }
    if (img.complete) {
      return Promise.resolve(img);
    }
    return new Promise((resolve, reject) => {
      img.onload = () => resolve(img);
      img.onerror = reject;
    });
  }
  function specialKeyUsed(e) {
    return "button" in e && e.button === 1 || e.ctrlKey || e.metaKey || e.altKey || e.shiftKey;
  }
  function getElementsFromOption(option, legacySelector, parent = document) {
    let elements = [];
    if (option instanceof Element) {
      elements = [option];
    } else if (option instanceof NodeList || Array.isArray(option)) {
      elements = Array.from(option);
    } else {
      const selector = typeof option === "string" ? option : legacySelector;
      if (selector) {
        elements = Array.from(parent.querySelectorAll(selector));
      }
    }
    return elements;
  }
  function isSafari() {
    return !!(navigator.vendor && navigator.vendor.match(/apple/i));
  }
  function getViewportSize(options, pswp) {
    if (options.getViewportSizeFn) {
      const newViewportSize = options.getViewportSizeFn(options, pswp);
      if (newViewportSize) {
        return newViewportSize;
      }
    }
    return {
      x: document.documentElement.clientWidth,
      // TODO: height on mobile is very incosistent due to toolbar
      // find a way to improve this
      //
      // document.documentElement.clientHeight - doesn't seem to work well
      y: window.innerHeight
    };
  }
  function parsePaddingOption(prop, options, viewportSize, itemData, index) {
    let paddingValue = 0;
    if (options.paddingFn) {
      paddingValue = options.paddingFn(viewportSize, itemData, index)[prop];
    } else if (options.padding) {
      paddingValue = options.padding[prop];
    } else {
      const legacyPropName = "padding" + prop[0].toUpperCase() + prop.slice(1);
      if (options[legacyPropName]) {
        paddingValue = options[legacyPropName];
      }
    }
    return Number(paddingValue) || 0;
  }
  function getPanAreaSize(options, viewportSize, itemData, index) {
    return {
      x: viewportSize.x - parsePaddingOption("left", options, viewportSize, itemData, index) - parsePaddingOption("right", options, viewportSize, itemData, index),
      y: viewportSize.y - parsePaddingOption("top", options, viewportSize, itemData, index) - parsePaddingOption("bottom", options, viewportSize, itemData, index)
    };
  }
  function project(initialVelocity, decelerationRate) {
    return initialVelocity * decelerationRate / (1 - decelerationRate);
  }
  function getZoomPointsCenter(p, p1, p2) {
    p.x = (p1.x + p2.x) / 2;
    p.y = (p1.y + p2.y) / 2;
    return p;
  }
  function didTapOnMainContent(event) {
    return !!/** @type {HTMLElement} */
    event.target.closest(".pswp__container");
  }
  function addElementHTML(htmlData) {
    if (typeof htmlData === "string") {
      return htmlData;
    }
    if (!htmlData || !htmlData.isCustomSVG) {
      return "";
    }
    const svgData = htmlData;
    let out = '<svg aria-hidden="true" class="pswp__icn" viewBox="0 0 %d %d" width="%d" height="%d">';
    out = out.split("%d").join(
      /** @type {string} */
      svgData.size || 32
    );
    if (svgData.outlineID) {
      out += '<use class="pswp__icn-shadow" xlink:href="#' + svgData.outlineID + '"/>';
    }
    out += svgData.inner;
    out += "</svg>";
    return out;
  }
  function initArrowButton(element, pswp, isNextButton) {
    element.classList.add("pswp__button--arrow");
    element.setAttribute("aria-controls", "pswp__items");
    pswp.on("change", () => {
      if (!pswp.options.loop) {
        if (isNextButton) {
          element.disabled = !(pswp.currIndex < pswp.getNumItems() - 1);
        } else {
          element.disabled = !(pswp.currIndex > 0);
        }
      }
    });
  }
  function setZoomedIn(el, isZoomedIn) {
    el.classList.toggle("pswp--zoomed-in", isZoomedIn);
  }
  function getBoundsByElement(el) {
    const thumbAreaRect = el.getBoundingClientRect();
    return {
      x: thumbAreaRect.left,
      y: thumbAreaRect.top,
      w: thumbAreaRect.width
    };
  }
  function getCroppedBoundsByElement(el, imageWidth, imageHeight) {
    const thumbAreaRect = el.getBoundingClientRect();
    const hRatio = thumbAreaRect.width / imageWidth;
    const vRatio = thumbAreaRect.height / imageHeight;
    const fillZoomLevel = hRatio > vRatio ? hRatio : vRatio;
    const offsetX = (thumbAreaRect.width - imageWidth * fillZoomLevel) / 2;
    const offsetY = (thumbAreaRect.height - imageHeight * fillZoomLevel) / 2;
    const bounds = {
      x: thumbAreaRect.left + offsetX,
      y: thumbAreaRect.top + offsetY,
      w: imageWidth * fillZoomLevel
    };
    bounds.innerRect = {
      w: thumbAreaRect.width,
      h: thumbAreaRect.height,
      x: offsetX,
      y: offsetY
    };
    return bounds;
  }
  function getThumbBounds(index, itemData, instance) {
    const event = instance.dispatch("thumbBounds", {
      index,
      itemData,
      instance
    });
    if (event.thumbBounds) {
      return event.thumbBounds;
    }
    const {
      element
    } = itemData;
    let thumbBounds;
    let thumbnail;
    if (element && instance.options.thumbSelector !== false) {
      const thumbSelector = instance.options.thumbSelector || "img";
      thumbnail = element.matches(thumbSelector) ? element : (
        /** @type {HTMLElement | null} */
        element.querySelector(thumbSelector)
      );
    }
    thumbnail = instance.applyFilters("thumbEl", thumbnail, itemData, index);
    if (thumbnail) {
      if (!itemData.thumbCropped) {
        thumbBounds = getBoundsByElement(thumbnail);
      } else {
        thumbBounds = getCroppedBoundsByElement(thumbnail, itemData.width || itemData.w || 0, itemData.height || itemData.h || 0);
      }
    }
    return instance.applyFilters("thumbBounds", thumbBounds, itemData, index);
  }
  function lazyLoadData(itemData, instance, index) {
    const content = instance.createContentFromData(itemData, index);
    let zoomLevel;
    const {
      options
    } = instance;
    if (options) {
      zoomLevel = new ZoomLevel(options, itemData, -1);
      let viewportSize;
      if (instance.pswp) {
        viewportSize = instance.pswp.viewportSize;
      } else {
        viewportSize = getViewportSize(options, instance);
      }
      const panAreaSize = getPanAreaSize(options, viewportSize, itemData, index);
      zoomLevel.update(content.width, content.height, panAreaSize);
    }
    content.lazyLoad();
    if (zoomLevel) {
      content.setDisplayedSize(Math.ceil(content.width * zoomLevel.initial), Math.ceil(content.height * zoomLevel.initial));
    }
    return content;
  }
  function lazyLoadSlide(index, instance) {
    const itemData = instance.getItemData(index);
    if (instance.dispatch("lazyLoadSlide", {
      index,
      itemData
    }).defaultPrevented) {
      return;
    }
    return lazyLoadData(itemData, instance, index);
  }
  var defaultCSSEasing, LOAD_STATE, supportsPassive, DOMEvents, PanBounds, MAX_IMAGE_WIDTH, ZoomLevel, Slide, PAN_END_FRICTION, VERTICAL_DRAG_FRICTION, MIN_RATIO_TO_CLOSE, MIN_NEXT_SLIDE_SPEED, DragHandler, UPPER_ZOOM_FRICTION, LOWER_ZOOM_FRICTION, ZoomHandler, TapHandler, AXIS_SWIPE_HYSTERISIS, DOUBLE_TAP_DELAY, MIN_TAP_DISTANCE, Gestures, MAIN_SCROLL_END_FRICTION, MainScroll, KeyboardKeyCodesMap, getKeyboardEventKey, Keyboard, DEFAULT_EASING, CSSAnimation, DEFAULT_NATURAL_FREQUENCY, DEFAULT_DAMPING_RATIO, SpringEaser, SpringAnimation, Animations, ScrollWheel, UIElement, arrowPrev, arrowNext, closeButton, zoomButton, loadingIndicator, counterIndicator, UI, PhotoSwipeEvent, Eventable, Placeholder, Content, MIN_SLIDES_TO_CACHE, ContentLoader, PhotoSwipeBase, MIN_OPACITY, Opener, defaultOptions, PhotoSwipe;
  var init_photoswipe_esm = __esm({
    "../../phoenix_kit_photos/assets/node_modules/photoswipe/dist/photoswipe.esm.js"() {
      defaultCSSEasing = "cubic-bezier(.4,0,.22,1)";
      LOAD_STATE = {
        IDLE: "idle",
        LOADING: "loading",
        LOADED: "loaded",
        ERROR: "error"
      };
      supportsPassive = false;
      try {
        window.addEventListener("test", null, Object.defineProperty({}, "passive", {
          get: () => {
            supportsPassive = true;
          }
        }));
      } catch (e) {
      }
      DOMEvents = class {
        constructor() {
          this._pool = [];
        }
        /**
         * Adds event listeners
         *
         * @param {PoolItem['target']} target
         * @param {PoolItem['type']} type Can be multiple, separated by space.
         * @param {PoolItem['listener']} listener
         * @param {PoolItem['passive']} [passive]
         */
        add(target, type, listener, passive) {
          this._toggleListener(target, type, listener, passive);
        }
        /**
         * Removes event listeners
         *
         * @param {PoolItem['target']} target
         * @param {PoolItem['type']} type
         * @param {PoolItem['listener']} listener
         * @param {PoolItem['passive']} [passive]
         */
        remove(target, type, listener, passive) {
          this._toggleListener(target, type, listener, passive, true);
        }
        /**
         * Removes all bound events
         */
        removeAll() {
          this._pool.forEach((poolItem) => {
            this._toggleListener(poolItem.target, poolItem.type, poolItem.listener, poolItem.passive, true, true);
          });
          this._pool = [];
        }
        /**
         * Adds or removes event
         *
         * @private
         * @param {PoolItem['target']} target
         * @param {PoolItem['type']} type
         * @param {PoolItem['listener']} listener
         * @param {PoolItem['passive']} [passive]
         * @param {boolean} [unbind] Whether the event should be added or removed
         * @param {boolean} [skipPool] Whether events pool should be skipped
         */
        _toggleListener(target, type, listener, passive, unbind, skipPool) {
          if (!target) {
            return;
          }
          const methodName = unbind ? "removeEventListener" : "addEventListener";
          const types = type.split(" ");
          types.forEach((eType) => {
            if (eType) {
              if (!skipPool) {
                if (unbind) {
                  this._pool = this._pool.filter((poolItem) => {
                    return poolItem.type !== eType || poolItem.listener !== listener || poolItem.target !== target;
                  });
                } else {
                  this._pool.push({
                    target,
                    type: eType,
                    listener,
                    passive
                  });
                }
              }
              const eventOptions = supportsPassive ? {
                passive: passive || false
              } : false;
              target[methodName](eType, listener, eventOptions);
            }
          });
        }
      };
      PanBounds = class {
        /**
         * @param {Slide} slide
         */
        constructor(slide) {
          this.slide = slide;
          this.currZoomLevel = 1;
          this.center = /** @type {Point} */
          {
            x: 0,
            y: 0
          };
          this.max = /** @type {Point} */
          {
            x: 0,
            y: 0
          };
          this.min = /** @type {Point} */
          {
            x: 0,
            y: 0
          };
        }
        /**
         * _getItemBounds
         *
         * @param {number} currZoomLevel
         */
        update(currZoomLevel) {
          this.currZoomLevel = currZoomLevel;
          if (!this.slide.width) {
            this.reset();
          } else {
            this._updateAxis("x");
            this._updateAxis("y");
            this.slide.pswp.dispatch("calcBounds", {
              slide: this.slide
            });
          }
        }
        /**
         * _calculateItemBoundsForAxis
         *
         * @param {Axis} axis
         */
        _updateAxis(axis) {
          const {
            pswp
          } = this.slide;
          const elSize = this.slide[axis === "x" ? "width" : "height"] * this.currZoomLevel;
          const paddingProp = axis === "x" ? "left" : "top";
          const padding = parsePaddingOption(paddingProp, pswp.options, pswp.viewportSize, this.slide.data, this.slide.index);
          const panAreaSize = this.slide.panAreaSize[axis];
          this.center[axis] = Math.round((panAreaSize - elSize) / 2) + padding;
          this.max[axis] = elSize > panAreaSize ? Math.round(panAreaSize - elSize) + padding : this.center[axis];
          this.min[axis] = elSize > panAreaSize ? padding : this.center[axis];
        }
        // _getZeroBounds
        reset() {
          this.center.x = 0;
          this.center.y = 0;
          this.max.x = 0;
          this.max.y = 0;
          this.min.x = 0;
          this.min.y = 0;
        }
        /**
         * Correct pan position if it's beyond the bounds
         *
         * @param {Axis} axis x or y
         * @param {number} panOffset
         * @returns {number}
         */
        correctPan(axis, panOffset) {
          return clamp(panOffset, this.max[axis], this.min[axis]);
        }
      };
      MAX_IMAGE_WIDTH = 4e3;
      ZoomLevel = class {
        /**
         * @param {PhotoSwipeOptions} options PhotoSwipe options
         * @param {SlideData} itemData Slide data
         * @param {number} index Slide index
         * @param {PhotoSwipe} [pswp] PhotoSwipe instance, can be undefined if not initialized yet
         */
        constructor(options, itemData, index, pswp) {
          this.pswp = pswp;
          this.options = options;
          this.itemData = itemData;
          this.index = index;
          this.panAreaSize = null;
          this.elementSize = null;
          this.fit = 1;
          this.fill = 1;
          this.vFill = 1;
          this.initial = 1;
          this.secondary = 1;
          this.max = 1;
          this.min = 1;
        }
        /**
         * Calculate initial, secondary and maximum zoom level for the specified slide.
         *
         * It should be called when either image or viewport size changes.
         *
         * @param {number} maxWidth
         * @param {number} maxHeight
         * @param {Point} panAreaSize
         */
        update(maxWidth, maxHeight, panAreaSize) {
          const elementSize = {
            x: maxWidth,
            y: maxHeight
          };
          this.elementSize = elementSize;
          this.panAreaSize = panAreaSize;
          const hRatio = panAreaSize.x / elementSize.x;
          const vRatio = panAreaSize.y / elementSize.y;
          this.fit = Math.min(1, hRatio < vRatio ? hRatio : vRatio);
          this.fill = Math.min(1, hRatio > vRatio ? hRatio : vRatio);
          this.vFill = Math.min(1, vRatio);
          this.initial = this._getInitial();
          this.secondary = this._getSecondary();
          this.max = Math.max(this.initial, this.secondary, this._getMax());
          this.min = Math.min(this.fit, this.initial, this.secondary);
          if (this.pswp) {
            this.pswp.dispatch("zoomLevelsUpdate", {
              zoomLevels: this,
              slideData: this.itemData
            });
          }
        }
        /**
         * Parses user-defined zoom option.
         *
         * @private
         * @param {'initial' | 'secondary' | 'max'} optionPrefix Zoom level option prefix (initial, secondary, max)
         * @returns { number | undefined }
         */
        _parseZoomLevelOption(optionPrefix) {
          const optionName = (
            /** @type {'initialZoomLevel' | 'secondaryZoomLevel' | 'maxZoomLevel'} */
            optionPrefix + "ZoomLevel"
          );
          const optionValue = this.options[optionName];
          if (!optionValue) {
            return;
          }
          if (typeof optionValue === "function") {
            return optionValue(this);
          }
          if (optionValue === "fill") {
            return this.fill;
          }
          if (optionValue === "fit") {
            return this.fit;
          }
          return Number(optionValue);
        }
        /**
         * Get zoom level to which image will be zoomed after double-tap gesture,
         * or when user clicks on zoom icon,
         * or mouse-click on image itself.
         * If you return 1 image will be zoomed to its original size.
         *
         * @private
         * @return {number}
         */
        _getSecondary() {
          let currZoomLevel = this._parseZoomLevelOption("secondary");
          if (currZoomLevel) {
            return currZoomLevel;
          }
          currZoomLevel = Math.min(1, this.fit * 3);
          if (this.elementSize && currZoomLevel * this.elementSize.x > MAX_IMAGE_WIDTH) {
            currZoomLevel = MAX_IMAGE_WIDTH / this.elementSize.x;
          }
          return currZoomLevel;
        }
        /**
         * Get initial image zoom level.
         *
         * @private
         * @return {number}
         */
        _getInitial() {
          return this._parseZoomLevelOption("initial") || this.fit;
        }
        /**
         * Maximum zoom level when user zooms
         * via zoom/pinch gesture,
         * via cmd/ctrl-wheel or via trackpad.
         *
         * @private
         * @return {number}
         */
        _getMax() {
          return this._parseZoomLevelOption("max") || Math.max(1, this.fit * 4);
        }
      };
      Slide = class {
        /**
         * @param {SlideData} data
         * @param {number} index
         * @param {PhotoSwipe} pswp
         */
        constructor(data, index, pswp) {
          this.data = data;
          this.index = index;
          this.pswp = pswp;
          this.isActive = index === pswp.currIndex;
          this.currentResolution = 0;
          this.panAreaSize = {
            x: 0,
            y: 0
          };
          this.pan = {
            x: 0,
            y: 0
          };
          this.isFirstSlide = this.isActive && !pswp.opener.isOpen;
          this.zoomLevels = new ZoomLevel(pswp.options, data, index, pswp);
          this.pswp.dispatch("gettingData", {
            slide: this,
            data: this.data,
            index
          });
          this.content = this.pswp.contentLoader.getContentBySlide(this);
          this.container = createElement("pswp__zoom-wrap", "div");
          this.holderElement = null;
          this.currZoomLevel = 1;
          this.width = this.content.width;
          this.height = this.content.height;
          this.heavyAppended = false;
          this.bounds = new PanBounds(this);
          this.prevDisplayedWidth = -1;
          this.prevDisplayedHeight = -1;
          this.pswp.dispatch("slideInit", {
            slide: this
          });
        }
        /**
         * If this slide is active/current/visible
         *
         * @param {boolean} isActive
         */
        setIsActive(isActive) {
          if (isActive && !this.isActive) {
            this.activate();
          } else if (!isActive && this.isActive) {
            this.deactivate();
          }
        }
        /**
         * Appends slide content to DOM
         *
         * @param {HTMLElement} holderElement
         */
        append(holderElement) {
          this.holderElement = holderElement;
          this.container.style.transformOrigin = "0 0";
          if (!this.data) {
            return;
          }
          this.calculateSize();
          this.load();
          this.updateContentSize();
          this.appendHeavy();
          this.holderElement.appendChild(this.container);
          this.zoomAndPanToInitial();
          this.pswp.dispatch("firstZoomPan", {
            slide: this
          });
          this.applyCurrentZoomPan();
          this.pswp.dispatch("afterSetContent", {
            slide: this
          });
          if (this.isActive) {
            this.activate();
          }
        }
        load() {
          this.content.load(false);
          this.pswp.dispatch("slideLoad", {
            slide: this
          });
        }
        /**
         * Append "heavy" DOM elements
         *
         * This may depend on a type of slide,
         * but generally these are large images.
         */
        appendHeavy() {
          const {
            pswp
          } = this;
          const appendHeavyNearby = true;
          if (this.heavyAppended || !pswp.opener.isOpen || pswp.mainScroll.isShifted() || !this.isActive && !appendHeavyNearby) {
            return;
          }
          if (this.pswp.dispatch("appendHeavy", {
            slide: this
          }).defaultPrevented) {
            return;
          }
          this.heavyAppended = true;
          this.content.append();
          this.pswp.dispatch("appendHeavyContent", {
            slide: this
          });
        }
        /**
         * Triggered when this slide is active (selected).
         *
         * If it's part of opening/closing transition -
         * activate() will trigger after the transition is ended.
         */
        activate() {
          this.isActive = true;
          this.appendHeavy();
          this.content.activate();
          this.pswp.dispatch("slideActivate", {
            slide: this
          });
        }
        /**
         * Triggered when this slide becomes inactive.
         *
         * Slide can become inactive only after it was active.
         */
        deactivate() {
          this.isActive = false;
          this.content.deactivate();
          if (this.currZoomLevel !== this.zoomLevels.initial) {
            this.calculateSize();
          }
          this.currentResolution = 0;
          this.zoomAndPanToInitial();
          this.applyCurrentZoomPan();
          this.updateContentSize();
          this.pswp.dispatch("slideDeactivate", {
            slide: this
          });
        }
        /**
         * The slide should destroy itself, it will never be used again.
         * (unbind all events and destroy internal components)
         */
        destroy() {
          this.content.hasSlide = false;
          this.content.remove();
          this.container.remove();
          this.pswp.dispatch("slideDestroy", {
            slide: this
          });
        }
        resize() {
          if (this.currZoomLevel === this.zoomLevels.initial || !this.isActive) {
            this.calculateSize();
            this.currentResolution = 0;
            this.zoomAndPanToInitial();
            this.applyCurrentZoomPan();
            this.updateContentSize();
          } else {
            this.calculateSize();
            this.bounds.update(this.currZoomLevel);
            this.panTo(this.pan.x, this.pan.y);
          }
        }
        /**
         * Apply size to current slide content,
         * based on the current resolution and scale.
         *
         * @param {boolean} [force] if size should be updated even if dimensions weren't changed
         */
        updateContentSize(force) {
          const scaleMultiplier = this.currentResolution || this.zoomLevels.initial;
          if (!scaleMultiplier) {
            return;
          }
          const width = Math.round(this.width * scaleMultiplier) || this.pswp.viewportSize.x;
          const height = Math.round(this.height * scaleMultiplier) || this.pswp.viewportSize.y;
          if (!this.sizeChanged(width, height) && !force) {
            return;
          }
          this.content.setDisplayedSize(width, height);
        }
        /**
         * @param {number} width
         * @param {number} height
         */
        sizeChanged(width, height) {
          if (width !== this.prevDisplayedWidth || height !== this.prevDisplayedHeight) {
            this.prevDisplayedWidth = width;
            this.prevDisplayedHeight = height;
            return true;
          }
          return false;
        }
        /** @returns {HTMLImageElement | HTMLDivElement | null | undefined} */
        getPlaceholderElement() {
          var _this$content$placeho;
          return (_this$content$placeho = this.content.placeholder) === null || _this$content$placeho === void 0 ? void 0 : _this$content$placeho.element;
        }
        /**
         * Zoom current slide image to...
         *
         * @param {number} destZoomLevel Destination zoom level.
         * @param {Point} [centerPoint]
         * Transform origin center point, or false if viewport center should be used.
         * @param {number | false} [transitionDuration] Transition duration, may be set to 0.
         * @param {boolean} [ignoreBounds] Minimum and maximum zoom levels will be ignored.
         */
        zoomTo(destZoomLevel, centerPoint, transitionDuration, ignoreBounds) {
          const {
            pswp
          } = this;
          if (!this.isZoomable() || pswp.mainScroll.isShifted()) {
            return;
          }
          pswp.dispatch("beforeZoomTo", {
            destZoomLevel,
            centerPoint,
            transitionDuration
          });
          pswp.animations.stopAllPan();
          const prevZoomLevel = this.currZoomLevel;
          if (!ignoreBounds) {
            destZoomLevel = clamp(destZoomLevel, this.zoomLevels.min, this.zoomLevels.max);
          }
          this.setZoomLevel(destZoomLevel);
          this.pan.x = this.calculateZoomToPanOffset("x", centerPoint, prevZoomLevel);
          this.pan.y = this.calculateZoomToPanOffset("y", centerPoint, prevZoomLevel);
          roundPoint(this.pan);
          const finishTransition = () => {
            this._setResolution(destZoomLevel);
            this.applyCurrentZoomPan();
          };
          if (!transitionDuration) {
            finishTransition();
          } else {
            pswp.animations.startTransition({
              isPan: true,
              name: "zoomTo",
              target: this.container,
              transform: this.getCurrentTransform(),
              onComplete: finishTransition,
              duration: transitionDuration,
              easing: pswp.options.easing
            });
          }
        }
        /**
         * @param {Point} [centerPoint]
         */
        toggleZoom(centerPoint) {
          this.zoomTo(this.currZoomLevel === this.zoomLevels.initial ? this.zoomLevels.secondary : this.zoomLevels.initial, centerPoint, this.pswp.options.zoomAnimationDuration);
        }
        /**
         * Updates zoom level property and recalculates new pan bounds,
         * unlike zoomTo it does not apply transform (use applyCurrentZoomPan)
         *
         * @param {number} currZoomLevel
         */
        setZoomLevel(currZoomLevel) {
          this.currZoomLevel = currZoomLevel;
          this.bounds.update(this.currZoomLevel);
        }
        /**
         * Get pan position after zoom at a given `point`.
         *
         * Always call setZoomLevel(newZoomLevel) beforehand to recalculate
         * pan bounds according to the new zoom level.
         *
         * @param {'x' | 'y'} axis
         * @param {Point} [point]
         * point based on which zoom is performed, usually refers to the current mouse position,
         * if false - viewport center will be used.
         * @param {number} [prevZoomLevel] Zoom level before new zoom was applied.
         * @returns {number}
         */
        calculateZoomToPanOffset(axis, point, prevZoomLevel) {
          const totalPanDistance = this.bounds.max[axis] - this.bounds.min[axis];
          if (totalPanDistance === 0) {
            return this.bounds.center[axis];
          }
          if (!point) {
            point = this.pswp.getViewportCenterPoint();
          }
          if (!prevZoomLevel) {
            prevZoomLevel = this.zoomLevels.initial;
          }
          const zoomFactor = this.currZoomLevel / prevZoomLevel;
          return this.bounds.correctPan(axis, (this.pan[axis] - point[axis]) * zoomFactor + point[axis]);
        }
        /**
         * Apply pan and keep it within bounds.
         *
         * @param {number} panX
         * @param {number} panY
         */
        panTo(panX, panY) {
          this.pan.x = this.bounds.correctPan("x", panX);
          this.pan.y = this.bounds.correctPan("y", panY);
          this.applyCurrentZoomPan();
        }
        /**
         * If the slide in the current state can be panned by the user
         * @returns {boolean}
         */
        isPannable() {
          return Boolean(this.width) && this.currZoomLevel > this.zoomLevels.fit;
        }
        /**
         * If the slide can be zoomed
         * @returns {boolean}
         */
        isZoomable() {
          return Boolean(this.width) && this.content.isZoomable();
        }
        /**
         * Apply transform and scale based on
         * the current pan position (this.pan) and zoom level (this.currZoomLevel)
         */
        applyCurrentZoomPan() {
          this._applyZoomTransform(this.pan.x, this.pan.y, this.currZoomLevel);
          if (this === this.pswp.currSlide) {
            this.pswp.dispatch("zoomPanUpdate", {
              slide: this
            });
          }
        }
        zoomAndPanToInitial() {
          this.currZoomLevel = this.zoomLevels.initial;
          this.bounds.update(this.currZoomLevel);
          equalizePoints(this.pan, this.bounds.center);
          this.pswp.dispatch("initialZoomPan", {
            slide: this
          });
        }
        /**
         * Set translate and scale based on current resolution
         *
         * @param {number} x
         * @param {number} y
         * @param {number} zoom
         * @private
         */
        _applyZoomTransform(x, y, zoom) {
          zoom /= this.currentResolution || this.zoomLevels.initial;
          setTransform(this.container, x, y, zoom);
        }
        calculateSize() {
          const {
            pswp
          } = this;
          equalizePoints(this.panAreaSize, getPanAreaSize(pswp.options, pswp.viewportSize, this.data, this.index));
          this.zoomLevels.update(this.width, this.height, this.panAreaSize);
          pswp.dispatch("calcSlideSize", {
            slide: this
          });
        }
        /** @returns {string} */
        getCurrentTransform() {
          const scale = this.currZoomLevel / (this.currentResolution || this.zoomLevels.initial);
          return toTransformString(this.pan.x, this.pan.y, scale);
        }
        /**
         * Set resolution and re-render the image.
         *
         * For example, if the real image size is 2000x1500,
         * and resolution is 0.5 - it will be rendered as 1000x750.
         *
         * Image with zoom level 2 and resolution 0.5 is
         * the same as image with zoom level 1 and resolution 1.
         *
         * Used to optimize animations and make
         * sure that browser renders image in the highest quality.
         * Also used by responsive images to load the correct one.
         *
         * @param {number} newResolution
         */
        _setResolution(newResolution) {
          if (newResolution === this.currentResolution) {
            return;
          }
          this.currentResolution = newResolution;
          this.updateContentSize();
          this.pswp.dispatch("resolutionChanged");
        }
      };
      PAN_END_FRICTION = 0.35;
      VERTICAL_DRAG_FRICTION = 0.6;
      MIN_RATIO_TO_CLOSE = 0.4;
      MIN_NEXT_SLIDE_SPEED = 0.5;
      DragHandler = class {
        /**
         * @param {Gestures} gestures
         */
        constructor(gestures) {
          this.gestures = gestures;
          this.pswp = gestures.pswp;
          this.startPan = {
            x: 0,
            y: 0
          };
        }
        start() {
          if (this.pswp.currSlide) {
            equalizePoints(this.startPan, this.pswp.currSlide.pan);
          }
          this.pswp.animations.stopAll();
        }
        change() {
          const {
            p1,
            prevP1,
            dragAxis
          } = this.gestures;
          const {
            currSlide
          } = this.pswp;
          if (dragAxis === "y" && this.pswp.options.closeOnVerticalDrag && currSlide && currSlide.currZoomLevel <= currSlide.zoomLevels.fit && !this.gestures.isMultitouch) {
            const panY = currSlide.pan.y + (p1.y - prevP1.y);
            if (!this.pswp.dispatch("verticalDrag", {
              panY
            }).defaultPrevented) {
              this._setPanWithFriction("y", panY, VERTICAL_DRAG_FRICTION);
              const bgOpacity = 1 - Math.abs(this._getVerticalDragRatio(currSlide.pan.y));
              this.pswp.applyBgOpacity(bgOpacity);
              currSlide.applyCurrentZoomPan();
            }
          } else {
            const mainScrollChanged = this._panOrMoveMainScroll("x");
            if (!mainScrollChanged) {
              this._panOrMoveMainScroll("y");
              if (currSlide) {
                roundPoint(currSlide.pan);
                currSlide.applyCurrentZoomPan();
              }
            }
          }
        }
        end() {
          const {
            velocity
          } = this.gestures;
          const {
            mainScroll,
            currSlide
          } = this.pswp;
          let indexDiff = 0;
          this.pswp.animations.stopAll();
          if (mainScroll.isShifted()) {
            const mainScrollShiftDiff = mainScroll.x - mainScroll.getCurrSlideX();
            const currentSlideVisibilityRatio = mainScrollShiftDiff / this.pswp.viewportSize.x;
            if (velocity.x < -MIN_NEXT_SLIDE_SPEED && currentSlideVisibilityRatio < 0 || velocity.x < 0.1 && currentSlideVisibilityRatio < -0.5) {
              indexDiff = 1;
              velocity.x = Math.min(velocity.x, 0);
            } else if (velocity.x > MIN_NEXT_SLIDE_SPEED && currentSlideVisibilityRatio > 0 || velocity.x > -0.1 && currentSlideVisibilityRatio > 0.5) {
              indexDiff = -1;
              velocity.x = Math.max(velocity.x, 0);
            }
            mainScroll.moveIndexBy(indexDiff, true, velocity.x);
          }
          if (currSlide && currSlide.currZoomLevel > currSlide.zoomLevels.max || this.gestures.isMultitouch) {
            this.gestures.zoomLevels.correctZoomPan(true);
          } else {
            this._finishPanGestureForAxis("x");
            this._finishPanGestureForAxis("y");
          }
        }
        /**
         * @private
         * @param {'x' | 'y'} axis
         */
        _finishPanGestureForAxis(axis) {
          const {
            velocity
          } = this.gestures;
          const {
            currSlide
          } = this.pswp;
          if (!currSlide) {
            return;
          }
          const {
            pan,
            bounds
          } = currSlide;
          const panPos = pan[axis];
          const restoreBgOpacity = this.pswp.bgOpacity < 1 && axis === "y";
          const decelerationRate = 0.995;
          const projectedPosition = panPos + project(velocity[axis], decelerationRate);
          if (restoreBgOpacity) {
            const vDragRatio = this._getVerticalDragRatio(panPos);
            const projectedVDragRatio = this._getVerticalDragRatio(projectedPosition);
            if (vDragRatio < 0 && projectedVDragRatio < -MIN_RATIO_TO_CLOSE || vDragRatio > 0 && projectedVDragRatio > MIN_RATIO_TO_CLOSE) {
              this.pswp.close();
              return;
            }
          }
          const correctedPanPosition = bounds.correctPan(axis, projectedPosition);
          if (panPos === correctedPanPosition) {
            return;
          }
          const dampingRatio = correctedPanPosition === projectedPosition ? 1 : 0.82;
          const initialBgOpacity = this.pswp.bgOpacity;
          const totalPanDist = correctedPanPosition - panPos;
          this.pswp.animations.startSpring({
            name: "panGesture" + axis,
            isPan: true,
            start: panPos,
            end: correctedPanPosition,
            velocity: velocity[axis],
            dampingRatio,
            onUpdate: (pos) => {
              if (restoreBgOpacity && this.pswp.bgOpacity < 1) {
                const animationProgressRatio = 1 - (correctedPanPosition - pos) / totalPanDist;
                this.pswp.applyBgOpacity(clamp(initialBgOpacity + (1 - initialBgOpacity) * animationProgressRatio, 0, 1));
              }
              pan[axis] = Math.floor(pos);
              currSlide.applyCurrentZoomPan();
            }
          });
        }
        /**
         * Update position of the main scroll,
         * or/and update pan position of the current slide.
         *
         * Should return true if it changes (or can change) main scroll.
         *
         * @private
         * @param {'x' | 'y'} axis
         * @returns {boolean}
         */
        _panOrMoveMainScroll(axis) {
          const {
            p1,
            dragAxis,
            prevP1,
            isMultitouch
          } = this.gestures;
          const {
            currSlide,
            mainScroll
          } = this.pswp;
          const delta = p1[axis] - prevP1[axis];
          const newMainScrollX = mainScroll.x + delta;
          if (!delta || !currSlide) {
            return false;
          }
          if (axis === "x" && !currSlide.isPannable() && !isMultitouch) {
            mainScroll.moveTo(newMainScrollX, true);
            return true;
          }
          const {
            bounds
          } = currSlide;
          const newPan = currSlide.pan[axis] + delta;
          if (this.pswp.options.allowPanToNext && dragAxis === "x" && axis === "x" && !isMultitouch) {
            const currSlideMainScrollX = mainScroll.getCurrSlideX();
            const mainScrollShiftDiff = mainScroll.x - currSlideMainScrollX;
            const isLeftToRight = delta > 0;
            const isRightToLeft = !isLeftToRight;
            if (newPan > bounds.min[axis] && isLeftToRight) {
              const wasAtMinPanPosition = bounds.min[axis] <= this.startPan[axis];
              if (wasAtMinPanPosition) {
                mainScroll.moveTo(newMainScrollX, true);
                return true;
              } else {
                this._setPanWithFriction(axis, newPan);
              }
            } else if (newPan < bounds.max[axis] && isRightToLeft) {
              const wasAtMaxPanPosition = this.startPan[axis] <= bounds.max[axis];
              if (wasAtMaxPanPosition) {
                mainScroll.moveTo(newMainScrollX, true);
                return true;
              } else {
                this._setPanWithFriction(axis, newPan);
              }
            } else {
              if (mainScrollShiftDiff !== 0) {
                if (mainScrollShiftDiff > 0) {
                  mainScroll.moveTo(Math.max(newMainScrollX, currSlideMainScrollX), true);
                  return true;
                } else if (mainScrollShiftDiff < 0) {
                  mainScroll.moveTo(Math.min(newMainScrollX, currSlideMainScrollX), true);
                  return true;
                }
              } else {
                this._setPanWithFriction(axis, newPan);
              }
            }
          } else {
            if (axis === "y") {
              if (!mainScroll.isShifted() && bounds.min.y !== bounds.max.y) {
                this._setPanWithFriction(axis, newPan);
              }
            } else {
              this._setPanWithFriction(axis, newPan);
            }
          }
          return false;
        }
        // If we move above - the ratio is negative
        // If we move below the ratio is positive
        /**
         * Relation between pan Y position and third of viewport height.
         *
         * When we are at initial position (center bounds) - the ratio is 0,
         * if position is shifted upwards - the ratio is negative,
         * if position is shifted downwards - the ratio is positive.
         *
         * @private
         * @param {number} panY The current pan Y position.
         * @returns {number}
         */
        _getVerticalDragRatio(panY) {
          var _this$pswp$currSlide$, _this$pswp$currSlide;
          return (panY - ((_this$pswp$currSlide$ = (_this$pswp$currSlide = this.pswp.currSlide) === null || _this$pswp$currSlide === void 0 ? void 0 : _this$pswp$currSlide.bounds.center.y) !== null && _this$pswp$currSlide$ !== void 0 ? _this$pswp$currSlide$ : 0)) / (this.pswp.viewportSize.y / 3);
        }
        /**
         * Set pan position of the current slide.
         * Apply friction if the position is beyond the pan bounds,
         * or if custom friction is defined.
         *
         * @private
         * @param {'x' | 'y'} axis
         * @param {number} potentialPan
         * @param {number} [customFriction] (0.1 - 1)
         */
        _setPanWithFriction(axis, potentialPan, customFriction) {
          const {
            currSlide
          } = this.pswp;
          if (!currSlide) {
            return;
          }
          const {
            pan,
            bounds
          } = currSlide;
          const correctedPan = bounds.correctPan(axis, potentialPan);
          if (correctedPan !== potentialPan || customFriction) {
            const delta = Math.round(potentialPan - pan[axis]);
            pan[axis] += delta * (customFriction || PAN_END_FRICTION);
          } else {
            pan[axis] = potentialPan;
          }
        }
      };
      UPPER_ZOOM_FRICTION = 0.05;
      LOWER_ZOOM_FRICTION = 0.15;
      ZoomHandler = class {
        /**
         * @param {Gestures} gestures
         */
        constructor(gestures) {
          this.gestures = gestures;
          this._startPan = {
            x: 0,
            y: 0
          };
          this._startZoomPoint = {
            x: 0,
            y: 0
          };
          this._zoomPoint = {
            x: 0,
            y: 0
          };
          this._wasOverFitZoomLevel = false;
          this._startZoomLevel = 1;
        }
        start() {
          const {
            currSlide
          } = this.gestures.pswp;
          if (currSlide) {
            this._startZoomLevel = currSlide.currZoomLevel;
            equalizePoints(this._startPan, currSlide.pan);
          }
          this.gestures.pswp.animations.stopAllPan();
          this._wasOverFitZoomLevel = false;
        }
        change() {
          const {
            p1,
            startP1,
            p2,
            startP2,
            pswp
          } = this.gestures;
          const {
            currSlide
          } = pswp;
          if (!currSlide) {
            return;
          }
          const minZoomLevel = currSlide.zoomLevels.min;
          const maxZoomLevel = currSlide.zoomLevels.max;
          if (!currSlide.isZoomable() || pswp.mainScroll.isShifted()) {
            return;
          }
          getZoomPointsCenter(this._startZoomPoint, startP1, startP2);
          getZoomPointsCenter(this._zoomPoint, p1, p2);
          let currZoomLevel = 1 / getDistanceBetween(startP1, startP2) * getDistanceBetween(p1, p2) * this._startZoomLevel;
          if (currZoomLevel > currSlide.zoomLevels.initial + currSlide.zoomLevels.initial / 15) {
            this._wasOverFitZoomLevel = true;
          }
          if (currZoomLevel < minZoomLevel) {
            if (pswp.options.pinchToClose && !this._wasOverFitZoomLevel && this._startZoomLevel <= currSlide.zoomLevels.initial) {
              const bgOpacity = 1 - (minZoomLevel - currZoomLevel) / (minZoomLevel / 1.2);
              if (!pswp.dispatch("pinchClose", {
                bgOpacity
              }).defaultPrevented) {
                pswp.applyBgOpacity(bgOpacity);
              }
            } else {
              currZoomLevel = minZoomLevel - (minZoomLevel - currZoomLevel) * LOWER_ZOOM_FRICTION;
            }
          } else if (currZoomLevel > maxZoomLevel) {
            currZoomLevel = maxZoomLevel + (currZoomLevel - maxZoomLevel) * UPPER_ZOOM_FRICTION;
          }
          currSlide.pan.x = this._calculatePanForZoomLevel("x", currZoomLevel);
          currSlide.pan.y = this._calculatePanForZoomLevel("y", currZoomLevel);
          currSlide.setZoomLevel(currZoomLevel);
          currSlide.applyCurrentZoomPan();
        }
        end() {
          const {
            pswp
          } = this.gestures;
          const {
            currSlide
          } = pswp;
          if ((!currSlide || currSlide.currZoomLevel < currSlide.zoomLevels.initial) && !this._wasOverFitZoomLevel && pswp.options.pinchToClose) {
            pswp.close();
          } else {
            this.correctZoomPan();
          }
        }
        /**
         * @private
         * @param {'x' | 'y'} axis
         * @param {number} currZoomLevel
         * @returns {number}
         */
        _calculatePanForZoomLevel(axis, currZoomLevel) {
          const zoomFactor = currZoomLevel / this._startZoomLevel;
          return this._zoomPoint[axis] - (this._startZoomPoint[axis] - this._startPan[axis]) * zoomFactor;
        }
        /**
         * Correct currZoomLevel and pan if they are
         * beyond minimum or maximum values.
         * With animation.
         *
         * @param {boolean} [ignoreGesture]
         * Wether gesture coordinates should be ignored when calculating destination pan position.
         */
        correctZoomPan(ignoreGesture) {
          const {
            pswp
          } = this.gestures;
          const {
            currSlide
          } = pswp;
          if (!(currSlide !== null && currSlide !== void 0 && currSlide.isZoomable())) {
            return;
          }
          if (this._zoomPoint.x === 0) {
            ignoreGesture = true;
          }
          const prevZoomLevel = currSlide.currZoomLevel;
          let destinationZoomLevel;
          let currZoomLevelNeedsChange = true;
          if (prevZoomLevel < currSlide.zoomLevels.initial) {
            destinationZoomLevel = currSlide.zoomLevels.initial;
          } else if (prevZoomLevel > currSlide.zoomLevels.max) {
            destinationZoomLevel = currSlide.zoomLevels.max;
          } else {
            currZoomLevelNeedsChange = false;
            destinationZoomLevel = prevZoomLevel;
          }
          const initialBgOpacity = pswp.bgOpacity;
          const restoreBgOpacity = pswp.bgOpacity < 1;
          const initialPan = equalizePoints({
            x: 0,
            y: 0
          }, currSlide.pan);
          let destinationPan = equalizePoints({
            x: 0,
            y: 0
          }, initialPan);
          if (ignoreGesture) {
            this._zoomPoint.x = 0;
            this._zoomPoint.y = 0;
            this._startZoomPoint.x = 0;
            this._startZoomPoint.y = 0;
            this._startZoomLevel = prevZoomLevel;
            equalizePoints(this._startPan, initialPan);
          }
          if (currZoomLevelNeedsChange) {
            destinationPan = {
              x: this._calculatePanForZoomLevel("x", destinationZoomLevel),
              y: this._calculatePanForZoomLevel("y", destinationZoomLevel)
            };
          }
          currSlide.setZoomLevel(destinationZoomLevel);
          destinationPan = {
            x: currSlide.bounds.correctPan("x", destinationPan.x),
            y: currSlide.bounds.correctPan("y", destinationPan.y)
          };
          currSlide.setZoomLevel(prevZoomLevel);
          const panNeedsChange = !pointsEqual(destinationPan, initialPan);
          if (!panNeedsChange && !currZoomLevelNeedsChange && !restoreBgOpacity) {
            currSlide._setResolution(destinationZoomLevel);
            currSlide.applyCurrentZoomPan();
            return;
          }
          pswp.animations.stopAllPan();
          pswp.animations.startSpring({
            isPan: true,
            start: 0,
            end: 1e3,
            velocity: 0,
            dampingRatio: 1,
            naturalFrequency: 40,
            onUpdate: (now) => {
              now /= 1e3;
              if (panNeedsChange || currZoomLevelNeedsChange) {
                if (panNeedsChange) {
                  currSlide.pan.x = initialPan.x + (destinationPan.x - initialPan.x) * now;
                  currSlide.pan.y = initialPan.y + (destinationPan.y - initialPan.y) * now;
                }
                if (currZoomLevelNeedsChange) {
                  const newZoomLevel = prevZoomLevel + (destinationZoomLevel - prevZoomLevel) * now;
                  currSlide.setZoomLevel(newZoomLevel);
                }
                currSlide.applyCurrentZoomPan();
              }
              if (restoreBgOpacity && pswp.bgOpacity < 1) {
                pswp.applyBgOpacity(clamp(initialBgOpacity + (1 - initialBgOpacity) * now, 0, 1));
              }
            },
            onComplete: () => {
              currSlide._setResolution(destinationZoomLevel);
              currSlide.applyCurrentZoomPan();
            }
          });
        }
      };
      TapHandler = class {
        /**
         * @param {Gestures} gestures
         */
        constructor(gestures) {
          this.gestures = gestures;
        }
        /**
         * @param {Point} point
         * @param {PointerEvent} originalEvent
         */
        click(point, originalEvent) {
          const targetClassList = (
            /** @type {HTMLElement} */
            originalEvent.target.classList
          );
          const isImageClick = targetClassList.contains("pswp__img");
          const isBackgroundClick = targetClassList.contains("pswp__item") || targetClassList.contains("pswp__zoom-wrap");
          if (isImageClick) {
            this._doClickOrTapAction("imageClick", point, originalEvent);
          } else if (isBackgroundClick) {
            this._doClickOrTapAction("bgClick", point, originalEvent);
          }
        }
        /**
         * @param {Point} point
         * @param {PointerEvent} originalEvent
         */
        tap(point, originalEvent) {
          if (didTapOnMainContent(originalEvent)) {
            this._doClickOrTapAction("tap", point, originalEvent);
          }
        }
        /**
         * @param {Point} point
         * @param {PointerEvent} originalEvent
         */
        doubleTap(point, originalEvent) {
          if (didTapOnMainContent(originalEvent)) {
            this._doClickOrTapAction("doubleTap", point, originalEvent);
          }
        }
        /**
         * @private
         * @param {Actions} actionName
         * @param {Point} point
         * @param {PointerEvent} originalEvent
         */
        _doClickOrTapAction(actionName, point, originalEvent) {
          var _this$gestures$pswp$e;
          const {
            pswp
          } = this.gestures;
          const {
            currSlide
          } = pswp;
          const actionFullName = (
            /** @type {AddPostfix<Actions, 'Action'>} */
            actionName + "Action"
          );
          const optionValue = pswp.options[actionFullName];
          if (pswp.dispatch(actionFullName, {
            point,
            originalEvent
          }).defaultPrevented) {
            return;
          }
          if (typeof optionValue === "function") {
            optionValue.call(pswp, point, originalEvent);
            return;
          }
          switch (optionValue) {
            case "close":
            case "next":
              pswp[optionValue]();
              break;
            case "zoom":
              currSlide === null || currSlide === void 0 || currSlide.toggleZoom(point);
              break;
            case "zoom-or-close":
              if (currSlide !== null && currSlide !== void 0 && currSlide.isZoomable() && currSlide.zoomLevels.secondary !== currSlide.zoomLevels.initial) {
                currSlide.toggleZoom(point);
              } else if (pswp.options.clickToCloseNonZoomable) {
                pswp.close();
              }
              break;
            case "toggle-controls":
              (_this$gestures$pswp$e = this.gestures.pswp.element) === null || _this$gestures$pswp$e === void 0 || _this$gestures$pswp$e.classList.toggle("pswp--ui-visible");
              break;
          }
        }
      };
      AXIS_SWIPE_HYSTERISIS = 10;
      DOUBLE_TAP_DELAY = 300;
      MIN_TAP_DISTANCE = 25;
      Gestures = class {
        /**
         * @param {PhotoSwipe} pswp
         */
        constructor(pswp) {
          this.pswp = pswp;
          this.dragAxis = null;
          this.p1 = {
            x: 0,
            y: 0
          };
          this.p2 = {
            x: 0,
            y: 0
          };
          this.prevP1 = {
            x: 0,
            y: 0
          };
          this.prevP2 = {
            x: 0,
            y: 0
          };
          this.startP1 = {
            x: 0,
            y: 0
          };
          this.startP2 = {
            x: 0,
            y: 0
          };
          this.velocity = {
            x: 0,
            y: 0
          };
          this._lastStartP1 = {
            x: 0,
            y: 0
          };
          this._intervalP1 = {
            x: 0,
            y: 0
          };
          this._numActivePoints = 0;
          this._ongoingPointers = [];
          this._touchEventEnabled = "ontouchstart" in window;
          this._pointerEventEnabled = !!window.PointerEvent;
          this.supportsTouch = this._touchEventEnabled || this._pointerEventEnabled && navigator.maxTouchPoints > 1;
          this._numActivePoints = 0;
          this._intervalTime = 0;
          this._velocityCalculated = false;
          this.isMultitouch = false;
          this.isDragging = false;
          this.isZooming = false;
          this.raf = null;
          this._tapTimer = null;
          if (!this.supportsTouch) {
            pswp.options.allowPanToNext = false;
          }
          this.drag = new DragHandler(this);
          this.zoomLevels = new ZoomHandler(this);
          this.tapHandler = new TapHandler(this);
          pswp.on("bindEvents", () => {
            pswp.events.add(
              pswp.scrollWrap,
              "click",
              /** @type EventListener */
              this._onClick.bind(this)
            );
            if (this._pointerEventEnabled) {
              this._bindEvents("pointer", "down", "up", "cancel");
            } else if (this._touchEventEnabled) {
              this._bindEvents("touch", "start", "end", "cancel");
              if (pswp.scrollWrap) {
                pswp.scrollWrap.ontouchmove = () => {
                };
                pswp.scrollWrap.ontouchend = () => {
                };
              }
            } else {
              this._bindEvents("mouse", "down", "up");
            }
          });
        }
        /**
         * @private
         * @param {'mouse' | 'touch' | 'pointer'} pref
         * @param {'down' | 'start'} down
         * @param {'up' | 'end'} up
         * @param {'cancel'} [cancel]
         */
        _bindEvents(pref, down, up, cancel) {
          const {
            pswp
          } = this;
          const {
            events
          } = pswp;
          const cancelEvent = cancel ? pref + cancel : "";
          events.add(
            pswp.scrollWrap,
            pref + down,
            /** @type EventListener */
            this.onPointerDown.bind(this)
          );
          events.add(
            window,
            pref + "move",
            /** @type EventListener */
            this.onPointerMove.bind(this)
          );
          events.add(
            window,
            pref + up,
            /** @type EventListener */
            this.onPointerUp.bind(this)
          );
          if (cancelEvent) {
            events.add(
              pswp.scrollWrap,
              cancelEvent,
              /** @type EventListener */
              this.onPointerUp.bind(this)
            );
          }
        }
        /**
         * @param {PointerEvent} e
         */
        onPointerDown(e) {
          const isMousePointer = e.type === "mousedown" || e.pointerType === "mouse";
          if (isMousePointer && e.button > 0) {
            return;
          }
          const {
            pswp
          } = this;
          if (!pswp.opener.isOpen) {
            e.preventDefault();
            return;
          }
          if (pswp.dispatch("pointerDown", {
            originalEvent: e
          }).defaultPrevented) {
            return;
          }
          if (isMousePointer) {
            pswp.mouseDetected();
            this._preventPointerEventBehaviour(e, "down");
          }
          pswp.animations.stopAll();
          this._updatePoints(e, "down");
          if (this._numActivePoints === 1) {
            this.dragAxis = null;
            equalizePoints(this.startP1, this.p1);
          }
          if (this._numActivePoints > 1) {
            this._clearTapTimer();
            this.isMultitouch = true;
          } else {
            this.isMultitouch = false;
          }
        }
        /**
         * @param {PointerEvent} e
         */
        onPointerMove(e) {
          this._preventPointerEventBehaviour(e, "move");
          if (!this._numActivePoints) {
            return;
          }
          this._updatePoints(e, "move");
          if (this.pswp.dispatch("pointerMove", {
            originalEvent: e
          }).defaultPrevented) {
            return;
          }
          if (this._numActivePoints === 1 && !this.isDragging) {
            if (!this.dragAxis) {
              this._calculateDragDirection();
            }
            if (this.dragAxis && !this.isDragging) {
              if (this.isZooming) {
                this.isZooming = false;
                this.zoomLevels.end();
              }
              this.isDragging = true;
              this._clearTapTimer();
              this._updateStartPoints();
              this._intervalTime = Date.now();
              this._velocityCalculated = false;
              equalizePoints(this._intervalP1, this.p1);
              this.velocity.x = 0;
              this.velocity.y = 0;
              this.drag.start();
              this._rafStopLoop();
              this._rafRenderLoop();
            }
          } else if (this._numActivePoints > 1 && !this.isZooming) {
            this._finishDrag();
            this.isZooming = true;
            this._updateStartPoints();
            this.zoomLevels.start();
            this._rafStopLoop();
            this._rafRenderLoop();
          }
        }
        /**
         * @private
         */
        _finishDrag() {
          if (this.isDragging) {
            this.isDragging = false;
            if (!this._velocityCalculated) {
              this._updateVelocity(true);
            }
            this.drag.end();
            this.dragAxis = null;
          }
        }
        /**
         * @param {PointerEvent} e
         */
        onPointerUp(e) {
          if (!this._numActivePoints) {
            return;
          }
          this._updatePoints(e, "up");
          if (this.pswp.dispatch("pointerUp", {
            originalEvent: e
          }).defaultPrevented) {
            return;
          }
          if (this._numActivePoints === 0) {
            this._rafStopLoop();
            if (this.isDragging) {
              this._finishDrag();
            } else if (!this.isZooming && !this.isMultitouch) {
              this._finishTap(e);
            }
          }
          if (this._numActivePoints < 2 && this.isZooming) {
            this.isZooming = false;
            this.zoomLevels.end();
            if (this._numActivePoints === 1) {
              this.dragAxis = null;
              this._updateStartPoints();
            }
          }
        }
        /**
         * @private
         */
        _rafRenderLoop() {
          if (this.isDragging || this.isZooming) {
            this._updateVelocity();
            if (this.isDragging) {
              if (!pointsEqual(this.p1, this.prevP1)) {
                this.drag.change();
              }
            } else {
              if (!pointsEqual(this.p1, this.prevP1) || !pointsEqual(this.p2, this.prevP2)) {
                this.zoomLevels.change();
              }
            }
            this._updatePrevPoints();
            this.raf = requestAnimationFrame(this._rafRenderLoop.bind(this));
          }
        }
        /**
         * Update velocity at 50ms interval
         *
         * @private
         * @param {boolean} [force]
         */
        _updateVelocity(force) {
          const time = Date.now();
          const duration = time - this._intervalTime;
          if (duration < 50 && !force) {
            return;
          }
          this.velocity.x = this._getVelocity("x", duration);
          this.velocity.y = this._getVelocity("y", duration);
          this._intervalTime = time;
          equalizePoints(this._intervalP1, this.p1);
          this._velocityCalculated = true;
        }
        /**
         * @private
         * @param {PointerEvent} e
         */
        _finishTap(e) {
          const {
            mainScroll
          } = this.pswp;
          if (mainScroll.isShifted()) {
            mainScroll.moveIndexBy(0, true);
            return;
          }
          if (e.type.indexOf("cancel") > 0) {
            return;
          }
          if (e.type === "mouseup" || e.pointerType === "mouse") {
            this.tapHandler.click(this.startP1, e);
            return;
          }
          const tapDelay = this.pswp.options.doubleTapAction ? DOUBLE_TAP_DELAY : 0;
          if (this._tapTimer) {
            this._clearTapTimer();
            if (getDistanceBetween(this._lastStartP1, this.startP1) < MIN_TAP_DISTANCE) {
              this.tapHandler.doubleTap(this.startP1, e);
            }
          } else {
            equalizePoints(this._lastStartP1, this.startP1);
            this._tapTimer = setTimeout(() => {
              this.tapHandler.tap(this.startP1, e);
              this._clearTapTimer();
            }, tapDelay);
          }
        }
        /**
         * @private
         */
        _clearTapTimer() {
          if (this._tapTimer) {
            clearTimeout(this._tapTimer);
            this._tapTimer = null;
          }
        }
        /**
         * Get velocity for axis
         *
         * @private
         * @param {'x' | 'y'} axis
         * @param {number} duration
         * @returns {number}
         */
        _getVelocity(axis, duration) {
          const displacement = this.p1[axis] - this._intervalP1[axis];
          if (Math.abs(displacement) > 1 && duration > 5) {
            return displacement / duration;
          }
          return 0;
        }
        /**
         * @private
         */
        _rafStopLoop() {
          if (this.raf) {
            cancelAnimationFrame(this.raf);
            this.raf = null;
          }
        }
        /**
         * @private
         * @param {PointerEvent} e
         * @param {'up' | 'down' | 'move'} pointerType Normalized pointer type
         */
        _preventPointerEventBehaviour(e, pointerType) {
          const preventPointerEvent = this.pswp.applyFilters("preventPointerEvent", true, e, pointerType);
          if (preventPointerEvent) {
            e.preventDefault();
          }
        }
        /**
         * Parses and normalizes points from the touch, mouse or pointer event.
         * Updates p1 and p2.
         *
         * @private
         * @param {PointerEvent | TouchEvent} e
         * @param {'up' | 'down' | 'move'} pointerType Normalized pointer type
         */
        _updatePoints(e, pointerType) {
          if (this._pointerEventEnabled) {
            const pointerEvent = (
              /** @type {PointerEvent} */
              e
            );
            const pointerIndex = this._ongoingPointers.findIndex((ongoingPointer) => {
              return ongoingPointer.id === pointerEvent.pointerId;
            });
            if (pointerType === "up" && pointerIndex > -1) {
              this._ongoingPointers.splice(pointerIndex, 1);
            } else if (pointerType === "down" && pointerIndex === -1) {
              this._ongoingPointers.push(this._convertEventPosToPoint(pointerEvent, {
                x: 0,
                y: 0
              }));
            } else if (pointerIndex > -1) {
              this._convertEventPosToPoint(pointerEvent, this._ongoingPointers[pointerIndex]);
            }
            this._numActivePoints = this._ongoingPointers.length;
            if (this._numActivePoints > 0) {
              equalizePoints(this.p1, this._ongoingPointers[0]);
            }
            if (this._numActivePoints > 1) {
              equalizePoints(this.p2, this._ongoingPointers[1]);
            }
          } else {
            const touchEvent = (
              /** @type {TouchEvent} */
              e
            );
            this._numActivePoints = 0;
            if (touchEvent.type.indexOf("touch") > -1) {
              if (touchEvent.touches && touchEvent.touches.length > 0) {
                this._convertEventPosToPoint(touchEvent.touches[0], this.p1);
                this._numActivePoints++;
                if (touchEvent.touches.length > 1) {
                  this._convertEventPosToPoint(touchEvent.touches[1], this.p2);
                  this._numActivePoints++;
                }
              }
            } else {
              this._convertEventPosToPoint(
                /** @type {PointerEvent} */
                e,
                this.p1
              );
              if (pointerType === "up") {
                this._numActivePoints = 0;
              } else {
                this._numActivePoints++;
              }
            }
          }
        }
        /** update points that were used during previous rAF tick
         * @private
         */
        _updatePrevPoints() {
          equalizePoints(this.prevP1, this.p1);
          equalizePoints(this.prevP2, this.p2);
        }
        /** update points at the start of gesture
         * @private
         */
        _updateStartPoints() {
          equalizePoints(this.startP1, this.p1);
          equalizePoints(this.startP2, this.p2);
          this._updatePrevPoints();
        }
        /** @private */
        _calculateDragDirection() {
          if (this.pswp.mainScroll.isShifted()) {
            this.dragAxis = "x";
          } else {
            const diff = Math.abs(this.p1.x - this.startP1.x) - Math.abs(this.p1.y - this.startP1.y);
            if (diff !== 0) {
              const axisToCheck = diff > 0 ? "x" : "y";
              if (Math.abs(this.p1[axisToCheck] - this.startP1[axisToCheck]) >= AXIS_SWIPE_HYSTERISIS) {
                this.dragAxis = axisToCheck;
              }
            }
          }
        }
        /**
         * Converts touch, pointer or mouse event
         * to PhotoSwipe point.
         *
         * @private
         * @param {Touch | PointerEvent} e
         * @param {Point} p
         * @returns {Point}
         */
        _convertEventPosToPoint(e, p) {
          p.x = e.pageX - this.pswp.offset.x;
          p.y = e.pageY - this.pswp.offset.y;
          if ("pointerId" in e) {
            p.id = e.pointerId;
          } else if (e.identifier !== void 0) {
            p.id = e.identifier;
          }
          return p;
        }
        /**
         * @private
         * @param {PointerEvent} e
         */
        _onClick(e) {
          if (this.pswp.mainScroll.isShifted()) {
            e.preventDefault();
            e.stopPropagation();
          }
        }
      };
      MAIN_SCROLL_END_FRICTION = 0.35;
      MainScroll = class {
        /**
         * @param {PhotoSwipe} pswp
         */
        constructor(pswp) {
          this.pswp = pswp;
          this.x = 0;
          this.slideWidth = 0;
          this._currPositionIndex = 0;
          this._prevPositionIndex = 0;
          this._containerShiftIndex = -1;
          this.itemHolders = [];
        }
        /**
         * Position the scroller and slide containers
         * according to viewport size.
         *
         * @param {boolean} [resizeSlides] Whether slides content should resized
         */
        resize(resizeSlides) {
          const {
            pswp
          } = this;
          const newSlideWidth = Math.round(pswp.viewportSize.x + pswp.viewportSize.x * pswp.options.spacing);
          const slideWidthChanged = newSlideWidth !== this.slideWidth;
          if (slideWidthChanged) {
            this.slideWidth = newSlideWidth;
            this.moveTo(this.getCurrSlideX());
          }
          this.itemHolders.forEach((itemHolder, index) => {
            if (slideWidthChanged) {
              setTransform(itemHolder.el, (index + this._containerShiftIndex) * this.slideWidth);
            }
            if (resizeSlides && itemHolder.slide) {
              itemHolder.slide.resize();
            }
          });
        }
        /**
         * Reset X position of the main scroller to zero
         */
        resetPosition() {
          this._currPositionIndex = 0;
          this._prevPositionIndex = 0;
          this.slideWidth = 0;
          this._containerShiftIndex = -1;
        }
        /**
         * Create and append array of three items
         * that hold data about slides in DOM
         */
        appendHolders() {
          this.itemHolders = [];
          for (let i = 0; i < 3; i++) {
            const el = createElement("pswp__item", "div", this.pswp.container);
            el.setAttribute("role", "group");
            el.setAttribute("aria-roledescription", "slide");
            el.setAttribute("aria-hidden", "true");
            el.style.display = i === 1 ? "block" : "none";
            this.itemHolders.push({
              el
              //index: -1
            });
          }
        }
        /**
         * Whether the main scroll can be horizontally swiped to the next or previous slide.
         * @returns {boolean}
         */
        canBeSwiped() {
          return this.pswp.getNumItems() > 1;
        }
        /**
         * Move main scroll by X amount of slides.
         * For example:
         *   `-1` will move to the previous slide,
         *    `0` will reset the scroll position of the current slide,
         *    `3` will move three slides forward
         *
         * If loop option is enabled - index will be automatically looped too,
         * (for example `-1` will move to the last slide of the gallery).
         *
         * @param {number} diff
         * @param {boolean} [animate]
         * @param {number} [velocityX]
         * @returns {boolean} whether index was changed or not
         */
        moveIndexBy(diff, animate, velocityX) {
          const {
            pswp
          } = this;
          let newIndex = pswp.potentialIndex + diff;
          const numSlides = pswp.getNumItems();
          if (pswp.canLoop()) {
            newIndex = pswp.getLoopedIndex(newIndex);
            const distance2 = (diff + numSlides) % numSlides;
            if (distance2 <= numSlides / 2) {
              diff = distance2;
            } else {
              diff = distance2 - numSlides;
            }
          } else {
            if (newIndex < 0) {
              newIndex = 0;
            } else if (newIndex >= numSlides) {
              newIndex = numSlides - 1;
            }
            diff = newIndex - pswp.potentialIndex;
          }
          pswp.potentialIndex = newIndex;
          this._currPositionIndex -= diff;
          pswp.animations.stopMainScroll();
          const destinationX = this.getCurrSlideX();
          if (!animate) {
            this.moveTo(destinationX);
            this.updateCurrItem();
          } else {
            pswp.animations.startSpring({
              isMainScroll: true,
              start: this.x,
              end: destinationX,
              velocity: velocityX || 0,
              naturalFrequency: 30,
              dampingRatio: 1,
              //0.7,
              onUpdate: (x) => {
                this.moveTo(x);
              },
              onComplete: () => {
                this.updateCurrItem();
                pswp.appendHeavy();
              }
            });
            let currDiff = pswp.potentialIndex - pswp.currIndex;
            if (pswp.canLoop()) {
              const currDistance = (currDiff + numSlides) % numSlides;
              if (currDistance <= numSlides / 2) {
                currDiff = currDistance;
              } else {
                currDiff = currDistance - numSlides;
              }
            }
            if (Math.abs(currDiff) > 1) {
              this.updateCurrItem();
            }
          }
          return Boolean(diff);
        }
        /**
         * X position of the main scroll for the current slide
         * (ignores position during dragging)
         * @returns {number}
         */
        getCurrSlideX() {
          return this.slideWidth * this._currPositionIndex;
        }
        /**
         * Whether scroll position is shifted.
         * For example, it will return true if the scroll is being dragged or animated.
         * @returns {boolean}
         */
        isShifted() {
          return this.x !== this.getCurrSlideX();
        }
        /**
         * Update slides X positions and set their content
         */
        updateCurrItem() {
          var _this$itemHolders$;
          const {
            pswp
          } = this;
          const positionDifference = this._prevPositionIndex - this._currPositionIndex;
          if (!positionDifference) {
            return;
          }
          this._prevPositionIndex = this._currPositionIndex;
          pswp.currIndex = pswp.potentialIndex;
          let diffAbs = Math.abs(positionDifference);
          let tempHolder;
          if (diffAbs >= 3) {
            this._containerShiftIndex += positionDifference + (positionDifference > 0 ? -3 : 3);
            diffAbs = 3;
            this.itemHolders.forEach((itemHolder) => {
              var _itemHolder$slide;
              (_itemHolder$slide = itemHolder.slide) === null || _itemHolder$slide === void 0 || _itemHolder$slide.destroy();
              itemHolder.slide = void 0;
            });
          }
          for (let i = 0; i < diffAbs; i++) {
            if (positionDifference > 0) {
              tempHolder = this.itemHolders.shift();
              if (tempHolder) {
                this.itemHolders[2] = tempHolder;
                this._containerShiftIndex++;
                setTransform(tempHolder.el, (this._containerShiftIndex + 2) * this.slideWidth);
                pswp.setContent(tempHolder, pswp.currIndex - diffAbs + i + 2);
              }
            } else {
              tempHolder = this.itemHolders.pop();
              if (tempHolder) {
                this.itemHolders.unshift(tempHolder);
                this._containerShiftIndex--;
                setTransform(tempHolder.el, this._containerShiftIndex * this.slideWidth);
                pswp.setContent(tempHolder, pswp.currIndex + diffAbs - i - 2);
              }
            }
          }
          if (Math.abs(this._containerShiftIndex) > 50 && !this.isShifted()) {
            this.resetPosition();
            this.resize();
          }
          pswp.animations.stopAllPan();
          this.itemHolders.forEach((itemHolder, i) => {
            if (itemHolder.slide) {
              itemHolder.slide.setIsActive(i === 1);
            }
          });
          pswp.currSlide = (_this$itemHolders$ = this.itemHolders[1]) === null || _this$itemHolders$ === void 0 ? void 0 : _this$itemHolders$.slide;
          pswp.contentLoader.updateLazy(positionDifference);
          if (pswp.currSlide) {
            pswp.currSlide.applyCurrentZoomPan();
          }
          pswp.dispatch("change");
        }
        /**
         * Move the X position of the main scroll container
         *
         * @param {number} x
         * @param {boolean} [dragging]
         */
        moveTo(x, dragging) {
          if (!this.pswp.canLoop() && dragging) {
            let newSlideIndexOffset = (this.slideWidth * this._currPositionIndex - x) / this.slideWidth;
            newSlideIndexOffset += this.pswp.currIndex;
            const delta = Math.round(x - this.x);
            if (newSlideIndexOffset < 0 && delta > 0 || newSlideIndexOffset >= this.pswp.getNumItems() - 1 && delta < 0) {
              x = this.x + delta * MAIN_SCROLL_END_FRICTION;
            }
          }
          this.x = x;
          if (this.pswp.container) {
            setTransform(this.pswp.container, x);
          }
          this.pswp.dispatch("moveMainScroll", {
            x,
            dragging: dragging !== null && dragging !== void 0 ? dragging : false
          });
        }
      };
      KeyboardKeyCodesMap = {
        Escape: 27,
        z: 90,
        ArrowLeft: 37,
        ArrowUp: 38,
        ArrowRight: 39,
        ArrowDown: 40,
        Tab: 9
      };
      getKeyboardEventKey = (key, isKeySupported) => {
        return isKeySupported ? key : KeyboardKeyCodesMap[key];
      };
      Keyboard = class {
        /**
         * @param {PhotoSwipe} pswp
         */
        constructor(pswp) {
          this.pswp = pswp;
          this._wasFocused = false;
          pswp.on("bindEvents", () => {
            if (pswp.options.trapFocus) {
              if (!pswp.options.initialPointerPos) {
                this._focusRoot();
              }
              pswp.events.add(
                document,
                "focusin",
                /** @type EventListener */
                this._onFocusIn.bind(this)
              );
            }
            pswp.events.add(
              document,
              "keydown",
              /** @type EventListener */
              this._onKeyDown.bind(this)
            );
          });
          const lastActiveElement = (
            /** @type {HTMLElement} */
            document.activeElement
          );
          pswp.on("destroy", () => {
            if (pswp.options.returnFocus && lastActiveElement && this._wasFocused) {
              lastActiveElement.focus();
            }
          });
        }
        /** @private */
        _focusRoot() {
          if (!this._wasFocused && this.pswp.element) {
            this.pswp.element.focus();
            this._wasFocused = true;
          }
        }
        /**
         * @private
         * @param {KeyboardEvent} e
         */
        _onKeyDown(e) {
          const {
            pswp
          } = this;
          if (pswp.dispatch("keydown", {
            originalEvent: e
          }).defaultPrevented) {
            return;
          }
          if (specialKeyUsed(e)) {
            return;
          }
          let keydownAction;
          let axis;
          let isForward = false;
          const isKeySupported = "key" in e;
          switch (isKeySupported ? e.key : e.keyCode) {
            case getKeyboardEventKey("Escape", isKeySupported):
              if (pswp.options.escKey) {
                keydownAction = "close";
              }
              break;
            case getKeyboardEventKey("z", isKeySupported):
              keydownAction = "toggleZoom";
              break;
            case getKeyboardEventKey("ArrowLeft", isKeySupported):
              axis = "x";
              break;
            case getKeyboardEventKey("ArrowUp", isKeySupported):
              axis = "y";
              break;
            case getKeyboardEventKey("ArrowRight", isKeySupported):
              axis = "x";
              isForward = true;
              break;
            case getKeyboardEventKey("ArrowDown", isKeySupported):
              isForward = true;
              axis = "y";
              break;
            case getKeyboardEventKey("Tab", isKeySupported):
              this._focusRoot();
              break;
          }
          if (axis) {
            e.preventDefault();
            const {
              currSlide
            } = pswp;
            if (pswp.options.arrowKeys && axis === "x" && pswp.getNumItems() > 1) {
              keydownAction = isForward ? "next" : "prev";
            } else if (currSlide && currSlide.currZoomLevel > currSlide.zoomLevels.fit) {
              currSlide.pan[axis] += isForward ? -80 : 80;
              currSlide.panTo(currSlide.pan.x, currSlide.pan.y);
            }
          }
          if (keydownAction) {
            e.preventDefault();
            pswp[keydownAction]();
          }
        }
        /**
         * Trap focus inside photoswipe
         *
         * @private
         * @param {FocusEvent} e
         */
        _onFocusIn(e) {
          const {
            template
          } = this.pswp;
          if (template && document !== e.target && template !== e.target && !template.contains(
            /** @type {Node} */
            e.target
          )) {
            template.focus();
          }
        }
      };
      DEFAULT_EASING = "cubic-bezier(.4,0,.22,1)";
      CSSAnimation = class {
        /**
         * onComplete can be unpredictable, be careful about current state
         *
         * @param {CssAnimationProps} props
         */
        constructor(props) {
          var _props$prop;
          this.props = props;
          const {
            target,
            onComplete,
            transform,
            onFinish = () => {
            },
            duration = 333,
            easing = DEFAULT_EASING
          } = props;
          this.onFinish = onFinish;
          const prop = transform ? "transform" : "opacity";
          const propValue = (_props$prop = props[prop]) !== null && _props$prop !== void 0 ? _props$prop : "";
          this._target = target;
          this._onComplete = onComplete;
          this._finished = false;
          this._onTransitionEnd = this._onTransitionEnd.bind(this);
          this._helperTimeout = setTimeout(() => {
            setTransitionStyle(target, prop, duration, easing);
            this._helperTimeout = setTimeout(() => {
              target.addEventListener("transitionend", this._onTransitionEnd, false);
              target.addEventListener("transitioncancel", this._onTransitionEnd, false);
              this._helperTimeout = setTimeout(() => {
                this._finalizeAnimation();
              }, duration + 500);
              target.style[prop] = propValue;
            }, 30);
          }, 0);
        }
        /**
         * @private
         * @param {TransitionEvent} e
         */
        _onTransitionEnd(e) {
          if (e.target === this._target) {
            this._finalizeAnimation();
          }
        }
        /**
         * @private
         */
        _finalizeAnimation() {
          if (!this._finished) {
            this._finished = true;
            this.onFinish();
            if (this._onComplete) {
              this._onComplete();
            }
          }
        }
        // Destroy is called automatically onFinish
        destroy() {
          if (this._helperTimeout) {
            clearTimeout(this._helperTimeout);
          }
          removeTransitionStyle(this._target);
          this._target.removeEventListener("transitionend", this._onTransitionEnd, false);
          this._target.removeEventListener("transitioncancel", this._onTransitionEnd, false);
          if (!this._finished) {
            this._finalizeAnimation();
          }
        }
      };
      DEFAULT_NATURAL_FREQUENCY = 12;
      DEFAULT_DAMPING_RATIO = 0.75;
      SpringEaser = class {
        /**
         * @param {number} initialVelocity Initial velocity, px per ms.
         *
         * @param {number} [dampingRatio]
         * Determines how bouncy animation will be.
         * From 0 to 1, 0 - always overshoot, 1 - do not overshoot.
         * "overshoot" refers to part of animation that
         * goes beyond the final value.
         *
         * @param {number} [naturalFrequency]
         * Determines how fast animation will slow down.
         * The higher value - the stiffer the transition will be,
         * and the faster it will slow down.
         * Recommended value from 10 to 50
         */
        constructor(initialVelocity, dampingRatio, naturalFrequency) {
          this.velocity = initialVelocity * 1e3;
          this._dampingRatio = dampingRatio || DEFAULT_DAMPING_RATIO;
          this._naturalFrequency = naturalFrequency || DEFAULT_NATURAL_FREQUENCY;
          this._dampedFrequency = this._naturalFrequency;
          if (this._dampingRatio < 1) {
            this._dampedFrequency *= Math.sqrt(1 - this._dampingRatio * this._dampingRatio);
          }
        }
        /**
         * @param {number} deltaPosition Difference between current and end position of the animation
         * @param {number} deltaTime Frame duration in milliseconds
         *
         * @returns {number} Displacement, relative to the end position.
         */
        easeFrame(deltaPosition, deltaTime) {
          let displacement = 0;
          let coeff;
          deltaTime /= 1e3;
          const naturalDumpingPow = Math.E ** (-this._dampingRatio * this._naturalFrequency * deltaTime);
          if (this._dampingRatio === 1) {
            coeff = this.velocity + this._naturalFrequency * deltaPosition;
            displacement = (deltaPosition + coeff * deltaTime) * naturalDumpingPow;
            this.velocity = displacement * -this._naturalFrequency + coeff * naturalDumpingPow;
          } else if (this._dampingRatio < 1) {
            coeff = 1 / this._dampedFrequency * (this._dampingRatio * this._naturalFrequency * deltaPosition + this.velocity);
            const dumpedFCos = Math.cos(this._dampedFrequency * deltaTime);
            const dumpedFSin = Math.sin(this._dampedFrequency * deltaTime);
            displacement = naturalDumpingPow * (deltaPosition * dumpedFCos + coeff * dumpedFSin);
            this.velocity = displacement * -this._naturalFrequency * this._dampingRatio + naturalDumpingPow * (-this._dampedFrequency * deltaPosition * dumpedFSin + this._dampedFrequency * coeff * dumpedFCos);
          }
          return displacement;
        }
      };
      SpringAnimation = class {
        /**
         * @param {SpringAnimationProps} props
         */
        constructor(props) {
          this.props = props;
          this._raf = 0;
          const {
            start,
            end,
            velocity,
            onUpdate,
            onComplete,
            onFinish = () => {
            },
            dampingRatio,
            naturalFrequency
          } = props;
          this.onFinish = onFinish;
          const easer = new SpringEaser(velocity, dampingRatio, naturalFrequency);
          let prevTime = Date.now();
          let deltaPosition = start - end;
          const animationLoop = () => {
            if (this._raf) {
              deltaPosition = easer.easeFrame(deltaPosition, Date.now() - prevTime);
              if (Math.abs(deltaPosition) < 1 && Math.abs(easer.velocity) < 50) {
                onUpdate(end);
                if (onComplete) {
                  onComplete();
                }
                this.onFinish();
              } else {
                prevTime = Date.now();
                onUpdate(deltaPosition + end);
                this._raf = requestAnimationFrame(animationLoop);
              }
            }
          };
          this._raf = requestAnimationFrame(animationLoop);
        }
        // Destroy is called automatically onFinish
        destroy() {
          if (this._raf >= 0) {
            cancelAnimationFrame(this._raf);
          }
          this._raf = 0;
        }
      };
      Animations = class {
        constructor() {
          this.activeAnimations = [];
        }
        /**
         * @param {SpringAnimationProps} props
         */
        startSpring(props) {
          this._start(props, true);
        }
        /**
         * @param {CssAnimationProps} props
         */
        startTransition(props) {
          this._start(props);
        }
        /**
         * @private
         * @param {AnimationProps} props
         * @param {boolean} [isSpring]
         * @returns {Animation}
         */
        _start(props, isSpring) {
          const animation = isSpring ? new SpringAnimation(
            /** @type SpringAnimationProps */
            props
          ) : new CSSAnimation(
            /** @type CssAnimationProps */
            props
          );
          this.activeAnimations.push(animation);
          animation.onFinish = () => this.stop(animation);
          return animation;
        }
        /**
         * @param {Animation} animation
         */
        stop(animation) {
          animation.destroy();
          const index = this.activeAnimations.indexOf(animation);
          if (index > -1) {
            this.activeAnimations.splice(index, 1);
          }
        }
        stopAll() {
          this.activeAnimations.forEach((animation) => {
            animation.destroy();
          });
          this.activeAnimations = [];
        }
        /**
         * Stop all pan or zoom transitions
         */
        stopAllPan() {
          this.activeAnimations = this.activeAnimations.filter((animation) => {
            if (animation.props.isPan) {
              animation.destroy();
              return false;
            }
            return true;
          });
        }
        stopMainScroll() {
          this.activeAnimations = this.activeAnimations.filter((animation) => {
            if (animation.props.isMainScroll) {
              animation.destroy();
              return false;
            }
            return true;
          });
        }
        /**
         * Returns true if main scroll transition is running
         */
        // isMainScrollRunning() {
        //   return this.activeAnimations.some((animation) => {
        //     return animation.props.isMainScroll;
        //   });
        // }
        /**
         * Returns true if any pan or zoom transition is running
         */
        isPanRunning() {
          return this.activeAnimations.some((animation) => {
            return animation.props.isPan;
          });
        }
      };
      ScrollWheel = class {
        /**
         * @param {PhotoSwipe} pswp
         */
        constructor(pswp) {
          this.pswp = pswp;
          pswp.events.add(
            pswp.element,
            "wheel",
            /** @type EventListener */
            this._onWheel.bind(this)
          );
        }
        /**
         * @private
         * @param {WheelEvent} e
         */
        _onWheel(e) {
          e.preventDefault();
          const {
            currSlide
          } = this.pswp;
          let {
            deltaX,
            deltaY
          } = e;
          if (!currSlide) {
            return;
          }
          if (this.pswp.dispatch("wheel", {
            originalEvent: e
          }).defaultPrevented) {
            return;
          }
          if (e.ctrlKey || this.pswp.options.wheelToZoom) {
            if (currSlide.isZoomable()) {
              let zoomFactor = -deltaY;
              if (e.deltaMode === 1) {
                zoomFactor *= 0.05;
              } else {
                zoomFactor *= e.deltaMode ? 1 : 2e-3;
              }
              zoomFactor = 2 ** zoomFactor;
              const destZoomLevel = currSlide.currZoomLevel * zoomFactor;
              currSlide.zoomTo(destZoomLevel, {
                x: e.clientX,
                y: e.clientY
              });
            }
          } else {
            if (currSlide.isPannable()) {
              if (e.deltaMode === 1) {
                deltaX *= 18;
                deltaY *= 18;
              }
              currSlide.panTo(currSlide.pan.x - deltaX, currSlide.pan.y - deltaY);
            }
          }
        }
      };
      UIElement = class {
        /**
         * @param {PhotoSwipe} pswp
         * @param {UIElementData} data
         */
        constructor(pswp, data) {
          var _container;
          const name = data.name || data.className;
          let elementHTML = data.html;
          if (pswp.options[name] === false) {
            return;
          }
          if (typeof pswp.options[name + "SVG"] === "string") {
            elementHTML = pswp.options[name + "SVG"];
          }
          pswp.dispatch("uiElementCreate", {
            data
          });
          let className = "";
          if (data.isButton) {
            className += "pswp__button ";
            className += data.className || `pswp__button--${data.name}`;
          } else {
            className += data.className || `pswp__${data.name}`;
          }
          let tagName = data.isButton ? data.tagName || "button" : data.tagName || "div";
          tagName = /** @type {keyof HTMLElementTagNameMap} */
          tagName.toLowerCase();
          const element = createElement(className, tagName);
          if (data.isButton) {
            if (tagName === "button") {
              element.type = "button";
            }
            let {
              title
            } = data;
            const {
              ariaLabel
            } = data;
            if (typeof pswp.options[name + "Title"] === "string") {
              title = pswp.options[name + "Title"];
            }
            if (title) {
              element.title = title;
            }
            const ariaText = ariaLabel || title;
            if (ariaText) {
              element.setAttribute("aria-label", ariaText);
            }
          }
          element.innerHTML = addElementHTML(elementHTML);
          if (data.onInit) {
            data.onInit(element, pswp);
          }
          if (data.onClick) {
            element.onclick = (e) => {
              if (typeof data.onClick === "string") {
                pswp[data.onClick]();
              } else if (typeof data.onClick === "function") {
                data.onClick(e, element, pswp);
              }
            };
          }
          const appendTo = data.appendTo || "bar";
          let container = pswp.element;
          if (appendTo === "bar") {
            if (!pswp.topBar) {
              pswp.topBar = createElement("pswp__top-bar pswp__hide-on-close", "div", pswp.scrollWrap);
            }
            container = pswp.topBar;
          } else {
            element.classList.add("pswp__hide-on-close");
            if (appendTo === "wrapper") {
              container = pswp.scrollWrap;
            }
          }
          (_container = container) === null || _container === void 0 || _container.appendChild(pswp.applyFilters("uiElement", element, data));
        }
      };
      arrowPrev = {
        name: "arrowPrev",
        className: "pswp__button--arrow--prev",
        title: "Previous",
        order: 10,
        isButton: true,
        appendTo: "wrapper",
        html: {
          isCustomSVG: true,
          size: 60,
          inner: '<path d="M29 43l-3 3-16-16 16-16 3 3-13 13 13 13z" id="pswp__icn-arrow"/>',
          outlineID: "pswp__icn-arrow"
        },
        onClick: "prev",
        onInit: initArrowButton
      };
      arrowNext = {
        name: "arrowNext",
        className: "pswp__button--arrow--next",
        title: "Next",
        order: 11,
        isButton: true,
        appendTo: "wrapper",
        html: {
          isCustomSVG: true,
          size: 60,
          inner: '<use xlink:href="#pswp__icn-arrow"/>',
          outlineID: "pswp__icn-arrow"
        },
        onClick: "next",
        onInit: (el, pswp) => {
          initArrowButton(el, pswp, true);
        }
      };
      closeButton = {
        name: "close",
        title: "Close",
        order: 20,
        isButton: true,
        html: {
          isCustomSVG: true,
          inner: '<path d="M24 10l-2-2-6 6-6-6-2 2 6 6-6 6 2 2 6-6 6 6 2-2-6-6z" id="pswp__icn-close"/>',
          outlineID: "pswp__icn-close"
        },
        onClick: "close"
      };
      zoomButton = {
        name: "zoom",
        title: "Zoom",
        order: 10,
        isButton: true,
        html: {
          isCustomSVG: true,
          // eslint-disable-next-line max-len
          inner: '<path d="M17.426 19.926a6 6 0 1 1 1.5-1.5L23 22.5 21.5 24l-4.074-4.074z" id="pswp__icn-zoom"/><path fill="currentColor" class="pswp__zoom-icn-bar-h" d="M11 16v-2h6v2z"/><path fill="currentColor" class="pswp__zoom-icn-bar-v" d="M13 12h2v6h-2z"/>',
          outlineID: "pswp__icn-zoom"
        },
        onClick: "toggleZoom"
      };
      loadingIndicator = {
        name: "preloader",
        appendTo: "bar",
        order: 7,
        html: {
          isCustomSVG: true,
          // eslint-disable-next-line max-len
          inner: '<path fill-rule="evenodd" clip-rule="evenodd" d="M21.2 16a5.2 5.2 0 1 1-5.2-5.2V8a8 8 0 1 0 8 8h-2.8Z" id="pswp__icn-loading"/>',
          outlineID: "pswp__icn-loading"
        },
        onInit: (indicatorElement, pswp) => {
          let isVisible;
          let delayTimeout = null;
          const toggleIndicatorClass = (className, add) => {
            indicatorElement.classList.toggle("pswp__preloader--" + className, add);
          };
          const setIndicatorVisibility = (visible) => {
            if (isVisible !== visible) {
              isVisible = visible;
              toggleIndicatorClass("active", visible);
            }
          };
          const updatePreloaderVisibility = () => {
            var _pswp$currSlide;
            if (!((_pswp$currSlide = pswp.currSlide) !== null && _pswp$currSlide !== void 0 && _pswp$currSlide.content.isLoading())) {
              setIndicatorVisibility(false);
              if (delayTimeout) {
                clearTimeout(delayTimeout);
                delayTimeout = null;
              }
              return;
            }
            if (!delayTimeout) {
              delayTimeout = setTimeout(() => {
                var _pswp$currSlide2;
                setIndicatorVisibility(Boolean((_pswp$currSlide2 = pswp.currSlide) === null || _pswp$currSlide2 === void 0 ? void 0 : _pswp$currSlide2.content.isLoading()));
                delayTimeout = null;
              }, pswp.options.preloaderDelay);
            }
          };
          pswp.on("change", updatePreloaderVisibility);
          pswp.on("loadComplete", (e) => {
            if (pswp.currSlide === e.slide) {
              updatePreloaderVisibility();
            }
          });
          if (pswp.ui) {
            pswp.ui.updatePreloaderVisibility = updatePreloaderVisibility;
          }
        }
      };
      counterIndicator = {
        name: "counter",
        order: 5,
        onInit: (counterElement, pswp) => {
          pswp.on("change", () => {
            counterElement.innerText = pswp.currIndex + 1 + pswp.options.indexIndicatorSep + pswp.getNumItems();
          });
        }
      };
      UI = class {
        /**
         * @param {PhotoSwipe} pswp
         */
        constructor(pswp) {
          this.pswp = pswp;
          this.isRegistered = false;
          this.uiElementsData = [];
          this.items = [];
          this.updatePreloaderVisibility = () => {
          };
          this._lastUpdatedZoomLevel = void 0;
        }
        init() {
          const {
            pswp
          } = this;
          this.isRegistered = false;
          this.uiElementsData = [closeButton, arrowPrev, arrowNext, zoomButton, loadingIndicator, counterIndicator];
          pswp.dispatch("uiRegister");
          this.uiElementsData.sort((a, b) => {
            return (a.order || 0) - (b.order || 0);
          });
          this.items = [];
          this.isRegistered = true;
          this.uiElementsData.forEach((uiElementData) => {
            this.registerElement(uiElementData);
          });
          pswp.on("change", () => {
            var _pswp$element;
            (_pswp$element = pswp.element) === null || _pswp$element === void 0 || _pswp$element.classList.toggle("pswp--one-slide", pswp.getNumItems() === 1);
          });
          pswp.on("zoomPanUpdate", () => this._onZoomPanUpdate());
        }
        /**
         * @param {UIElementData} elementData
         */
        registerElement(elementData) {
          if (this.isRegistered) {
            this.items.push(new UIElement(this.pswp, elementData));
          } else {
            this.uiElementsData.push(elementData);
          }
        }
        /**
         * Fired each time zoom or pan position is changed.
         * Update classes that control visibility of zoom button and cursor icon.
         *
         * @private
         */
        _onZoomPanUpdate() {
          const {
            template,
            currSlide,
            options
          } = this.pswp;
          if (this.pswp.opener.isClosing || !template || !currSlide) {
            return;
          }
          let {
            currZoomLevel
          } = currSlide;
          if (!this.pswp.opener.isOpen) {
            currZoomLevel = currSlide.zoomLevels.initial;
          }
          if (currZoomLevel === this._lastUpdatedZoomLevel) {
            return;
          }
          this._lastUpdatedZoomLevel = currZoomLevel;
          const currZoomLevelDiff = currSlide.zoomLevels.initial - currSlide.zoomLevels.secondary;
          if (Math.abs(currZoomLevelDiff) < 0.01 || !currSlide.isZoomable()) {
            setZoomedIn(template, false);
            template.classList.remove("pswp--zoom-allowed");
            return;
          }
          template.classList.add("pswp--zoom-allowed");
          const potentialZoomLevel = currZoomLevel === currSlide.zoomLevels.initial ? currSlide.zoomLevels.secondary : currSlide.zoomLevels.initial;
          setZoomedIn(template, potentialZoomLevel <= currZoomLevel);
          if (options.imageClickAction === "zoom" || options.imageClickAction === "zoom-or-close") {
            template.classList.add("pswp--click-to-zoom");
          }
        }
      };
      PhotoSwipeEvent = class {
        /**
         * @param {T} type
         * @param {PhotoSwipeEventsMap[T]} [details]
         */
        constructor(type, details2) {
          this.type = type;
          this.defaultPrevented = false;
          if (details2) {
            Object.assign(this, details2);
          }
        }
        preventDefault() {
          this.defaultPrevented = true;
        }
      };
      Eventable = class {
        constructor() {
          this._listeners = {};
          this._filters = {};
          this.pswp = void 0;
          this.options = void 0;
        }
        /**
         * @template {keyof PhotoSwipeFiltersMap} T
         * @param {T} name
         * @param {PhotoSwipeFiltersMap[T]} fn
         * @param {number} priority
         */
        addFilter(name, fn, priority = 100) {
          var _this$_filters$name, _this$_filters$name2, _this$pswp;
          if (!this._filters[name]) {
            this._filters[name] = [];
          }
          (_this$_filters$name = this._filters[name]) === null || _this$_filters$name === void 0 || _this$_filters$name.push({
            fn,
            priority
          });
          (_this$_filters$name2 = this._filters[name]) === null || _this$_filters$name2 === void 0 || _this$_filters$name2.sort((f1, f2) => f1.priority - f2.priority);
          (_this$pswp = this.pswp) === null || _this$pswp === void 0 || _this$pswp.addFilter(name, fn, priority);
        }
        /**
         * @template {keyof PhotoSwipeFiltersMap} T
         * @param {T} name
         * @param {PhotoSwipeFiltersMap[T]} fn
         */
        removeFilter(name, fn) {
          if (this._filters[name]) {
            this._filters[name] = this._filters[name].filter((filter) => filter.fn !== fn);
          }
          if (this.pswp) {
            this.pswp.removeFilter(name, fn);
          }
        }
        /**
         * @template {keyof PhotoSwipeFiltersMap} T
         * @param {T} name
         * @param {Parameters<PhotoSwipeFiltersMap[T]>} args
         * @returns {Parameters<PhotoSwipeFiltersMap[T]>[0]}
         */
        applyFilters(name, ...args) {
          var _this$_filters$name3;
          (_this$_filters$name3 = this._filters[name]) === null || _this$_filters$name3 === void 0 || _this$_filters$name3.forEach((filter) => {
            args[0] = filter.fn.apply(this, args);
          });
          return args[0];
        }
        /**
         * @template {keyof PhotoSwipeEventsMap} T
         * @param {T} name
         * @param {EventCallback<T>} fn
         */
        on(name, fn) {
          var _this$_listeners$name, _this$pswp2;
          if (!this._listeners[name]) {
            this._listeners[name] = [];
          }
          (_this$_listeners$name = this._listeners[name]) === null || _this$_listeners$name === void 0 || _this$_listeners$name.push(fn);
          (_this$pswp2 = this.pswp) === null || _this$pswp2 === void 0 || _this$pswp2.on(name, fn);
        }
        /**
         * @template {keyof PhotoSwipeEventsMap} T
         * @param {T} name
         * @param {EventCallback<T>} fn
         */
        off(name, fn) {
          var _this$pswp3;
          if (this._listeners[name]) {
            this._listeners[name] = this._listeners[name].filter((listener) => fn !== listener);
          }
          (_this$pswp3 = this.pswp) === null || _this$pswp3 === void 0 || _this$pswp3.off(name, fn);
        }
        /**
         * @template {keyof PhotoSwipeEventsMap} T
         * @param {T} name
         * @param {PhotoSwipeEventsMap[T]} [details]
         * @returns {AugmentedEvent<T>}
         */
        dispatch(name, details2) {
          var _this$_listeners$name2;
          if (this.pswp) {
            return this.pswp.dispatch(name, details2);
          }
          const event = (
            /** @type {AugmentedEvent<T>} */
            new PhotoSwipeEvent(name, details2)
          );
          (_this$_listeners$name2 = this._listeners[name]) === null || _this$_listeners$name2 === void 0 || _this$_listeners$name2.forEach((listener) => {
            listener.call(this, event);
          });
          return event;
        }
      };
      Placeholder = class {
        /**
         * @param {string | false} imageSrc
         * @param {HTMLElement} container
         */
        constructor(imageSrc, container) {
          this.element = createElement("pswp__img pswp__img--placeholder", imageSrc ? "img" : "div", container);
          if (imageSrc) {
            const imgEl = (
              /** @type {HTMLImageElement} */
              this.element
            );
            imgEl.decoding = "async";
            imgEl.alt = "";
            imgEl.src = imageSrc;
            imgEl.setAttribute("role", "presentation");
          }
          this.element.setAttribute("aria-hidden", "true");
        }
        /**
         * @param {number} width
         * @param {number} height
         */
        setDisplayedSize(width, height) {
          if (!this.element) {
            return;
          }
          if (this.element.tagName === "IMG") {
            setWidthHeight(this.element, 250, "auto");
            this.element.style.transformOrigin = "0 0";
            this.element.style.transform = toTransformString(0, 0, width / 250);
          } else {
            setWidthHeight(this.element, width, height);
          }
        }
        destroy() {
          var _this$element;
          if ((_this$element = this.element) !== null && _this$element !== void 0 && _this$element.parentNode) {
            this.element.remove();
          }
          this.element = null;
        }
      };
      Content = class {
        /**
         * @param {SlideData} itemData Slide data
         * @param {PhotoSwipeBase} instance PhotoSwipe or PhotoSwipeLightbox instance
         * @param {number} index
         */
        constructor(itemData, instance, index) {
          this.instance = instance;
          this.data = itemData;
          this.index = index;
          this.element = void 0;
          this.placeholder = void 0;
          this.slide = void 0;
          this.displayedImageWidth = 0;
          this.displayedImageHeight = 0;
          this.width = Number(this.data.w) || Number(this.data.width) || 0;
          this.height = Number(this.data.h) || Number(this.data.height) || 0;
          this.isAttached = false;
          this.hasSlide = false;
          this.isDecoding = false;
          this.state = LOAD_STATE.IDLE;
          if (this.data.type) {
            this.type = this.data.type;
          } else if (this.data.src) {
            this.type = "image";
          } else {
            this.type = "html";
          }
          this.instance.dispatch("contentInit", {
            content: this
          });
        }
        removePlaceholder() {
          if (this.placeholder && !this.keepPlaceholder()) {
            setTimeout(() => {
              if (this.placeholder) {
                this.placeholder.destroy();
                this.placeholder = void 0;
              }
            }, 1e3);
          }
        }
        /**
         * Preload content
         *
         * @param {boolean} isLazy
         * @param {boolean} [reload]
         */
        load(isLazy, reload) {
          if (this.slide && this.usePlaceholder()) {
            if (!this.placeholder) {
              const placeholderSrc = this.instance.applyFilters(
                "placeholderSrc",
                // use  image-based placeholder only for the first slide,
                // as rendering (even small stretched thumbnail) is an expensive operation
                this.data.msrc && this.slide.isFirstSlide ? this.data.msrc : false,
                this
              );
              this.placeholder = new Placeholder(placeholderSrc, this.slide.container);
            } else {
              const placeholderEl = this.placeholder.element;
              if (placeholderEl && !placeholderEl.parentElement) {
                this.slide.container.prepend(placeholderEl);
              }
            }
          }
          if (this.element && !reload) {
            return;
          }
          if (this.instance.dispatch("contentLoad", {
            content: this,
            isLazy
          }).defaultPrevented) {
            return;
          }
          if (this.isImageContent()) {
            this.element = createElement("pswp__img", "img");
            if (this.displayedImageWidth) {
              this.loadImage(isLazy);
            }
          } else {
            this.element = createElement("pswp__content", "div");
            this.element.innerHTML = this.data.html || "";
          }
          if (reload && this.slide) {
            this.slide.updateContentSize(true);
          }
        }
        /**
         * Preload image
         *
         * @param {boolean} isLazy
         */
        loadImage(isLazy) {
          var _this$data$src, _this$data$alt;
          if (!this.isImageContent() || !this.element || this.instance.dispatch("contentLoadImage", {
            content: this,
            isLazy
          }).defaultPrevented) {
            return;
          }
          const imageElement = (
            /** @type HTMLImageElement */
            this.element
          );
          this.updateSrcsetSizes();
          if (this.data.srcset) {
            imageElement.srcset = this.data.srcset;
          }
          imageElement.src = (_this$data$src = this.data.src) !== null && _this$data$src !== void 0 ? _this$data$src : "";
          imageElement.alt = (_this$data$alt = this.data.alt) !== null && _this$data$alt !== void 0 ? _this$data$alt : "";
          this.state = LOAD_STATE.LOADING;
          if (imageElement.complete) {
            this.onLoaded();
          } else {
            imageElement.onload = () => {
              this.onLoaded();
            };
            imageElement.onerror = () => {
              this.onError();
            };
          }
        }
        /**
         * Assign slide to content
         *
         * @param {Slide} slide
         */
        setSlide(slide) {
          this.slide = slide;
          this.hasSlide = true;
          this.instance = slide.pswp;
        }
        /**
         * Content load success handler
         */
        onLoaded() {
          this.state = LOAD_STATE.LOADED;
          if (this.slide && this.element) {
            this.instance.dispatch("loadComplete", {
              slide: this.slide,
              content: this
            });
            if (this.slide.isActive && this.slide.heavyAppended && !this.element.parentNode) {
              this.append();
              this.slide.updateContentSize(true);
            }
            if (this.state === LOAD_STATE.LOADED || this.state === LOAD_STATE.ERROR) {
              this.removePlaceholder();
            }
          }
        }
        /**
         * Content load error handler
         */
        onError() {
          this.state = LOAD_STATE.ERROR;
          if (this.slide) {
            this.displayError();
            this.instance.dispatch("loadComplete", {
              slide: this.slide,
              isError: true,
              content: this
            });
            this.instance.dispatch("loadError", {
              slide: this.slide,
              content: this
            });
          }
        }
        /**
         * @returns {Boolean} If the content is currently loading
         */
        isLoading() {
          return this.instance.applyFilters("isContentLoading", this.state === LOAD_STATE.LOADING, this);
        }
        /**
         * @returns {Boolean} If the content is in error state
         */
        isError() {
          return this.state === LOAD_STATE.ERROR;
        }
        /**
         * @returns {boolean} If the content is image
         */
        isImageContent() {
          return this.type === "image";
        }
        /**
         * Update content size
         *
         * @param {Number} width
         * @param {Number} height
         */
        setDisplayedSize(width, height) {
          if (!this.element) {
            return;
          }
          if (this.placeholder) {
            this.placeholder.setDisplayedSize(width, height);
          }
          if (this.instance.dispatch("contentResize", {
            content: this,
            width,
            height
          }).defaultPrevented) {
            return;
          }
          setWidthHeight(this.element, width, height);
          if (this.isImageContent() && !this.isError()) {
            const isInitialSizeUpdate = !this.displayedImageWidth && width;
            this.displayedImageWidth = width;
            this.displayedImageHeight = height;
            if (isInitialSizeUpdate) {
              this.loadImage(false);
            } else {
              this.updateSrcsetSizes();
            }
            if (this.slide) {
              this.instance.dispatch("imageSizeChange", {
                slide: this.slide,
                width,
                height,
                content: this
              });
            }
          }
        }
        /**
         * @returns {boolean} If the content can be zoomed
         */
        isZoomable() {
          return this.instance.applyFilters("isContentZoomable", this.isImageContent() && this.state !== LOAD_STATE.ERROR, this);
        }
        /**
         * Update image srcset sizes attribute based on width and height
         */
        updateSrcsetSizes() {
          if (!this.isImageContent() || !this.element || !this.data.srcset) {
            return;
          }
          const image = (
            /** @type HTMLImageElement */
            this.element
          );
          const sizesWidth = this.instance.applyFilters("srcsetSizesWidth", this.displayedImageWidth, this);
          if (!image.dataset.largestUsedSize || sizesWidth > parseInt(image.dataset.largestUsedSize, 10)) {
            image.sizes = sizesWidth + "px";
            image.dataset.largestUsedSize = String(sizesWidth);
          }
        }
        /**
         * @returns {boolean} If content should use a placeholder (from msrc by default)
         */
        usePlaceholder() {
          return this.instance.applyFilters("useContentPlaceholder", this.isImageContent(), this);
        }
        /**
         * Preload content with lazy-loading param
         */
        lazyLoad() {
          if (this.instance.dispatch("contentLazyLoad", {
            content: this
          }).defaultPrevented) {
            return;
          }
          this.load(true);
        }
        /**
         * @returns {boolean} If placeholder should be kept after content is loaded
         */
        keepPlaceholder() {
          return this.instance.applyFilters("isKeepingPlaceholder", this.isLoading(), this);
        }
        /**
         * Destroy the content
         */
        destroy() {
          this.hasSlide = false;
          this.slide = void 0;
          if (this.instance.dispatch("contentDestroy", {
            content: this
          }).defaultPrevented) {
            return;
          }
          this.remove();
          if (this.placeholder) {
            this.placeholder.destroy();
            this.placeholder = void 0;
          }
          if (this.isImageContent() && this.element) {
            this.element.onload = null;
            this.element.onerror = null;
            this.element = void 0;
          }
        }
        /**
         * Display error message
         */
        displayError() {
          if (this.slide) {
            var _this$instance$option, _this$instance$option2;
            let errorMsgEl = createElement("pswp__error-msg", "div");
            errorMsgEl.innerText = (_this$instance$option = (_this$instance$option2 = this.instance.options) === null || _this$instance$option2 === void 0 ? void 0 : _this$instance$option2.errorMsg) !== null && _this$instance$option !== void 0 ? _this$instance$option : "";
            errorMsgEl = /** @type {HTMLDivElement} */
            this.instance.applyFilters("contentErrorElement", errorMsgEl, this);
            this.element = createElement("pswp__content pswp__error-msg-container", "div");
            this.element.appendChild(errorMsgEl);
            this.slide.container.innerText = "";
            this.slide.container.appendChild(this.element);
            this.slide.updateContentSize(true);
            this.removePlaceholder();
          }
        }
        /**
         * Append the content
         */
        append() {
          if (this.isAttached || !this.element) {
            return;
          }
          this.isAttached = true;
          if (this.state === LOAD_STATE.ERROR) {
            this.displayError();
            return;
          }
          if (this.instance.dispatch("contentAppend", {
            content: this
          }).defaultPrevented) {
            return;
          }
          const supportsDecode = "decode" in this.element;
          if (this.isImageContent()) {
            if (supportsDecode && this.slide && (!this.slide.isActive || isSafari())) {
              this.isDecoding = true;
              this.element.decode().catch(() => {
              }).finally(() => {
                this.isDecoding = false;
                this.appendImage();
              });
            } else {
              this.appendImage();
            }
          } else if (this.slide && !this.element.parentNode) {
            this.slide.container.appendChild(this.element);
          }
        }
        /**
         * Activate the slide,
         * active slide is generally the current one,
         * meaning the user can see it.
         */
        activate() {
          if (this.instance.dispatch("contentActivate", {
            content: this
          }).defaultPrevented || !this.slide) {
            return;
          }
          if (this.isImageContent() && this.isDecoding && !isSafari()) {
            this.appendImage();
          } else if (this.isError()) {
            this.load(false, true);
          }
          if (this.slide.holderElement) {
            this.slide.holderElement.setAttribute("aria-hidden", "false");
          }
        }
        /**
         * Deactivate the content
         */
        deactivate() {
          this.instance.dispatch("contentDeactivate", {
            content: this
          });
          if (this.slide && this.slide.holderElement) {
            this.slide.holderElement.setAttribute("aria-hidden", "true");
          }
        }
        /**
         * Remove the content from DOM
         */
        remove() {
          this.isAttached = false;
          if (this.instance.dispatch("contentRemove", {
            content: this
          }).defaultPrevented) {
            return;
          }
          if (this.element && this.element.parentNode) {
            this.element.remove();
          }
          if (this.placeholder && this.placeholder.element) {
            this.placeholder.element.remove();
          }
        }
        /**
         * Append the image content to slide container
         */
        appendImage() {
          if (!this.isAttached) {
            return;
          }
          if (this.instance.dispatch("contentAppendImage", {
            content: this
          }).defaultPrevented) {
            return;
          }
          if (this.slide && this.element && !this.element.parentNode) {
            this.slide.container.appendChild(this.element);
          }
          if (this.state === LOAD_STATE.LOADED || this.state === LOAD_STATE.ERROR) {
            this.removePlaceholder();
          }
        }
      };
      MIN_SLIDES_TO_CACHE = 5;
      ContentLoader = class {
        /**
         * @param {PhotoSwipe} pswp
         */
        constructor(pswp) {
          this.pswp = pswp;
          this.limit = Math.max(pswp.options.preload[0] + pswp.options.preload[1] + 1, MIN_SLIDES_TO_CACHE);
          this._cachedItems = [];
        }
        /**
         * Lazy load nearby slides based on `preload` option.
         *
         * @param {number} [diff] Difference between slide indexes that was changed recently, or 0.
         */
        updateLazy(diff) {
          const {
            pswp
          } = this;
          if (pswp.dispatch("lazyLoad").defaultPrevented) {
            return;
          }
          const {
            preload
          } = pswp.options;
          const isForward = diff === void 0 ? true : diff >= 0;
          let i;
          for (i = 0; i <= preload[1]; i++) {
            this.loadSlideByIndex(pswp.currIndex + (isForward ? i : -i));
          }
          for (i = 1; i <= preload[0]; i++) {
            this.loadSlideByIndex(pswp.currIndex + (isForward ? -i : i));
          }
        }
        /**
         * @param {number} initialIndex
         */
        loadSlideByIndex(initialIndex) {
          const index = this.pswp.getLoopedIndex(initialIndex);
          let content = this.getContentByIndex(index);
          if (!content) {
            content = lazyLoadSlide(index, this.pswp);
            if (content) {
              this.addToCache(content);
            }
          }
        }
        /**
         * @param {Slide} slide
         * @returns {Content}
         */
        getContentBySlide(slide) {
          let content = this.getContentByIndex(slide.index);
          if (!content) {
            content = this.pswp.createContentFromData(slide.data, slide.index);
            this.addToCache(content);
          }
          content.setSlide(slide);
          return content;
        }
        /**
         * @param {Content} content
         */
        addToCache(content) {
          this.removeByIndex(content.index);
          this._cachedItems.push(content);
          if (this._cachedItems.length > this.limit) {
            const indexToRemove = this._cachedItems.findIndex((item) => {
              return !item.isAttached && !item.hasSlide;
            });
            if (indexToRemove !== -1) {
              const removedItem = this._cachedItems.splice(indexToRemove, 1)[0];
              removedItem.destroy();
            }
          }
        }
        /**
         * Removes an image from cache, does not destroy() it, just removes.
         *
         * @param {number} index
         */
        removeByIndex(index) {
          const indexToRemove = this._cachedItems.findIndex((item) => item.index === index);
          if (indexToRemove !== -1) {
            this._cachedItems.splice(indexToRemove, 1);
          }
        }
        /**
         * @param {number} index
         * @returns {Content | undefined}
         */
        getContentByIndex(index) {
          return this._cachedItems.find((content) => content.index === index);
        }
        destroy() {
          this._cachedItems.forEach((content) => content.destroy());
          this._cachedItems = [];
        }
      };
      PhotoSwipeBase = class extends Eventable {
        /**
         * Get total number of slides
         *
         * @returns {number}
         */
        getNumItems() {
          var _this$options;
          let numItems = 0;
          const dataSource = (_this$options = this.options) === null || _this$options === void 0 ? void 0 : _this$options.dataSource;
          if (dataSource && "length" in dataSource) {
            numItems = dataSource.length;
          } else if (dataSource && "gallery" in dataSource) {
            if (!dataSource.items) {
              dataSource.items = this._getGalleryDOMElements(dataSource.gallery);
            }
            if (dataSource.items) {
              numItems = dataSource.items.length;
            }
          }
          const event = this.dispatch("numItems", {
            dataSource,
            numItems
          });
          return this.applyFilters("numItems", event.numItems, dataSource);
        }
        /**
         * @param {SlideData} slideData
         * @param {number} index
         * @returns {Content}
         */
        createContentFromData(slideData, index) {
          return new Content(slideData, this, index);
        }
        /**
         * Get item data by index.
         *
         * "item data" should contain normalized information that PhotoSwipe needs to generate a slide.
         * For example, it may contain properties like
         * `src`, `srcset`, `w`, `h`, which will be used to generate a slide with image.
         *
         * @param {number} index
         * @returns {SlideData}
         */
        getItemData(index) {
          var _this$options2;
          const dataSource = (_this$options2 = this.options) === null || _this$options2 === void 0 ? void 0 : _this$options2.dataSource;
          let dataSourceItem = {};
          if (Array.isArray(dataSource)) {
            dataSourceItem = dataSource[index];
          } else if (dataSource && "gallery" in dataSource) {
            if (!dataSource.items) {
              dataSource.items = this._getGalleryDOMElements(dataSource.gallery);
            }
            dataSourceItem = dataSource.items[index];
          }
          let itemData = dataSourceItem;
          if (itemData instanceof Element) {
            itemData = this._domElementToItemData(itemData);
          }
          const event = this.dispatch("itemData", {
            itemData: itemData || {},
            index
          });
          return this.applyFilters("itemData", event.itemData, index);
        }
        /**
         * Get array of gallery DOM elements,
         * based on childSelector and gallery element.
         *
         * @param {HTMLElement} galleryElement
         * @returns {HTMLElement[]}
         */
        _getGalleryDOMElements(galleryElement) {
          var _this$options3, _this$options4;
          if ((_this$options3 = this.options) !== null && _this$options3 !== void 0 && _this$options3.children || (_this$options4 = this.options) !== null && _this$options4 !== void 0 && _this$options4.childSelector) {
            return getElementsFromOption(this.options.children, this.options.childSelector, galleryElement) || [];
          }
          return [galleryElement];
        }
        /**
         * Converts DOM element to item data object.
         *
         * @param {HTMLElement} element DOM element
         * @returns {SlideData}
         */
        _domElementToItemData(element) {
          const itemData = {
            element
          };
          const linkEl = (
            /** @type {HTMLAnchorElement} */
            element.tagName === "A" ? element : element.querySelector("a")
          );
          if (linkEl) {
            itemData.src = linkEl.dataset.pswpSrc || linkEl.href;
            if (linkEl.dataset.pswpSrcset) {
              itemData.srcset = linkEl.dataset.pswpSrcset;
            }
            itemData.width = linkEl.dataset.pswpWidth ? parseInt(linkEl.dataset.pswpWidth, 10) : 0;
            itemData.height = linkEl.dataset.pswpHeight ? parseInt(linkEl.dataset.pswpHeight, 10) : 0;
            itemData.w = itemData.width;
            itemData.h = itemData.height;
            if (linkEl.dataset.pswpType) {
              itemData.type = linkEl.dataset.pswpType;
            }
            const thumbnailEl = element.querySelector("img");
            if (thumbnailEl) {
              var _thumbnailEl$getAttri;
              itemData.msrc = thumbnailEl.currentSrc || thumbnailEl.src;
              itemData.alt = (_thumbnailEl$getAttri = thumbnailEl.getAttribute("alt")) !== null && _thumbnailEl$getAttri !== void 0 ? _thumbnailEl$getAttri : "";
            }
            if (linkEl.dataset.pswpCropped || linkEl.dataset.cropped) {
              itemData.thumbCropped = true;
            }
          }
          return this.applyFilters("domItemData", itemData, element, linkEl);
        }
        /**
         * Lazy-load by slide data
         *
         * @param {SlideData} itemData Data about the slide
         * @param {number} index
         * @returns {Content} Image that is being decoded or false.
         */
        lazyLoadData(itemData, index) {
          return lazyLoadData(itemData, this, index);
        }
      };
      MIN_OPACITY = 3e-3;
      Opener = class {
        /**
         * @param {PhotoSwipe} pswp
         */
        constructor(pswp) {
          this.pswp = pswp;
          this.isClosed = true;
          this.isOpen = false;
          this.isClosing = false;
          this.isOpening = false;
          this._duration = void 0;
          this._useAnimation = false;
          this._croppedZoom = false;
          this._animateRootOpacity = false;
          this._animateBgOpacity = false;
          this._placeholder = void 0;
          this._opacityElement = void 0;
          this._cropContainer1 = void 0;
          this._cropContainer2 = void 0;
          this._thumbBounds = void 0;
          this._prepareOpen = this._prepareOpen.bind(this);
          pswp.on("firstZoomPan", this._prepareOpen);
        }
        open() {
          this._prepareOpen();
          this._start();
        }
        close() {
          if (this.isClosed || this.isClosing || this.isOpening) {
            return;
          }
          const slide = this.pswp.currSlide;
          this.isOpen = false;
          this.isOpening = false;
          this.isClosing = true;
          this._duration = this.pswp.options.hideAnimationDuration;
          if (slide && slide.currZoomLevel * slide.width >= this.pswp.options.maxWidthToAnimate) {
            this._duration = 0;
          }
          this._applyStartProps();
          setTimeout(() => {
            this._start();
          }, this._croppedZoom ? 30 : 0);
        }
        /** @private */
        _prepareOpen() {
          this.pswp.off("firstZoomPan", this._prepareOpen);
          if (!this.isOpening) {
            const slide = this.pswp.currSlide;
            this.isOpening = true;
            this.isClosing = false;
            this._duration = this.pswp.options.showAnimationDuration;
            if (slide && slide.zoomLevels.initial * slide.width >= this.pswp.options.maxWidthToAnimate) {
              this._duration = 0;
            }
            this._applyStartProps();
          }
        }
        /** @private */
        _applyStartProps() {
          const {
            pswp
          } = this;
          const slide = this.pswp.currSlide;
          const {
            options
          } = pswp;
          if (options.showHideAnimationType === "fade") {
            options.showHideOpacity = true;
            this._thumbBounds = void 0;
          } else if (options.showHideAnimationType === "none") {
            options.showHideOpacity = false;
            this._duration = 0;
            this._thumbBounds = void 0;
          } else if (this.isOpening && pswp._initialThumbBounds) {
            this._thumbBounds = pswp._initialThumbBounds;
          } else {
            this._thumbBounds = this.pswp.getThumbBounds();
          }
          this._placeholder = slide === null || slide === void 0 ? void 0 : slide.getPlaceholderElement();
          pswp.animations.stopAll();
          this._useAnimation = Boolean(this._duration && this._duration > 50);
          this._animateZoom = Boolean(this._thumbBounds) && (slide === null || slide === void 0 ? void 0 : slide.content.usePlaceholder()) && (!this.isClosing || !pswp.mainScroll.isShifted());
          if (!this._animateZoom) {
            this._animateRootOpacity = true;
            if (this.isOpening && slide) {
              slide.zoomAndPanToInitial();
              slide.applyCurrentZoomPan();
            }
          } else {
            var _options$showHideOpac;
            this._animateRootOpacity = (_options$showHideOpac = options.showHideOpacity) !== null && _options$showHideOpac !== void 0 ? _options$showHideOpac : false;
          }
          this._animateBgOpacity = !this._animateRootOpacity && this.pswp.options.bgOpacity > MIN_OPACITY;
          this._opacityElement = this._animateRootOpacity ? pswp.element : pswp.bg;
          if (!this._useAnimation) {
            this._duration = 0;
            this._animateZoom = false;
            this._animateBgOpacity = false;
            this._animateRootOpacity = true;
            if (this.isOpening) {
              if (pswp.element) {
                pswp.element.style.opacity = String(MIN_OPACITY);
              }
              pswp.applyBgOpacity(1);
            }
            return;
          }
          if (this._animateZoom && this._thumbBounds && this._thumbBounds.innerRect) {
            var _this$pswp$currSlide;
            this._croppedZoom = true;
            this._cropContainer1 = this.pswp.container;
            this._cropContainer2 = (_this$pswp$currSlide = this.pswp.currSlide) === null || _this$pswp$currSlide === void 0 ? void 0 : _this$pswp$currSlide.holderElement;
            if (pswp.container) {
              pswp.container.style.overflow = "hidden";
              pswp.container.style.width = pswp.viewportSize.x + "px";
            }
          } else {
            this._croppedZoom = false;
          }
          if (this.isOpening) {
            if (this._animateRootOpacity) {
              if (pswp.element) {
                pswp.element.style.opacity = String(MIN_OPACITY);
              }
              pswp.applyBgOpacity(1);
            } else {
              if (this._animateBgOpacity && pswp.bg) {
                pswp.bg.style.opacity = String(MIN_OPACITY);
              }
              if (pswp.element) {
                pswp.element.style.opacity = "1";
              }
            }
            if (this._animateZoom) {
              this._setClosedStateZoomPan();
              if (this._placeholder) {
                this._placeholder.style.willChange = "transform";
                this._placeholder.style.opacity = String(MIN_OPACITY);
              }
            }
          } else if (this.isClosing) {
            if (pswp.mainScroll.itemHolders[0]) {
              pswp.mainScroll.itemHolders[0].el.style.display = "none";
            }
            if (pswp.mainScroll.itemHolders[2]) {
              pswp.mainScroll.itemHolders[2].el.style.display = "none";
            }
            if (this._croppedZoom) {
              if (pswp.mainScroll.x !== 0) {
                pswp.mainScroll.resetPosition();
                pswp.mainScroll.resize();
              }
            }
          }
        }
        /** @private */
        _start() {
          if (this.isOpening && this._useAnimation && this._placeholder && this._placeholder.tagName === "IMG") {
            new Promise((resolve) => {
              let decoded = false;
              let isDelaying = true;
              decodeImage(
                /** @type {HTMLImageElement} */
                this._placeholder
              ).finally(() => {
                decoded = true;
                if (!isDelaying) {
                  resolve(true);
                }
              });
              setTimeout(() => {
                isDelaying = false;
                if (decoded) {
                  resolve(true);
                }
              }, 50);
              setTimeout(resolve, 250);
            }).finally(() => this._initiate());
          } else {
            this._initiate();
          }
        }
        /** @private */
        _initiate() {
          var _this$pswp$element, _this$pswp$element2;
          (_this$pswp$element = this.pswp.element) === null || _this$pswp$element === void 0 || _this$pswp$element.style.setProperty("--pswp-transition-duration", this._duration + "ms");
          this.pswp.dispatch(this.isOpening ? "openingAnimationStart" : "closingAnimationStart");
          this.pswp.dispatch(
            /** @type {'initialZoomIn' | 'initialZoomOut'} */
            "initialZoom" + (this.isOpening ? "In" : "Out")
          );
          (_this$pswp$element2 = this.pswp.element) === null || _this$pswp$element2 === void 0 || _this$pswp$element2.classList.toggle("pswp--ui-visible", this.isOpening);
          if (this.isOpening) {
            if (this._placeholder) {
              this._placeholder.style.opacity = "1";
            }
            this._animateToOpenState();
          } else if (this.isClosing) {
            this._animateToClosedState();
          }
          if (!this._useAnimation) {
            this._onAnimationComplete();
          }
        }
        /** @private */
        _onAnimationComplete() {
          const {
            pswp
          } = this;
          this.isOpen = this.isOpening;
          this.isClosed = this.isClosing;
          this.isOpening = false;
          this.isClosing = false;
          pswp.dispatch(this.isOpen ? "openingAnimationEnd" : "closingAnimationEnd");
          pswp.dispatch(
            /** @type {'initialZoomInEnd' | 'initialZoomOutEnd'} */
            "initialZoom" + (this.isOpen ? "InEnd" : "OutEnd")
          );
          if (this.isClosed) {
            pswp.destroy();
          } else if (this.isOpen) {
            var _pswp$currSlide;
            if (this._animateZoom && pswp.container) {
              pswp.container.style.overflow = "visible";
              pswp.container.style.width = "100%";
            }
            (_pswp$currSlide = pswp.currSlide) === null || _pswp$currSlide === void 0 || _pswp$currSlide.applyCurrentZoomPan();
          }
        }
        /** @private */
        _animateToOpenState() {
          const {
            pswp
          } = this;
          if (this._animateZoom) {
            if (this._croppedZoom && this._cropContainer1 && this._cropContainer2) {
              this._animateTo(this._cropContainer1, "transform", "translate3d(0,0,0)");
              this._animateTo(this._cropContainer2, "transform", "none");
            }
            if (pswp.currSlide) {
              pswp.currSlide.zoomAndPanToInitial();
              this._animateTo(pswp.currSlide.container, "transform", pswp.currSlide.getCurrentTransform());
            }
          }
          if (this._animateBgOpacity && pswp.bg) {
            this._animateTo(pswp.bg, "opacity", String(pswp.options.bgOpacity));
          }
          if (this._animateRootOpacity && pswp.element) {
            this._animateTo(pswp.element, "opacity", "1");
          }
        }
        /** @private */
        _animateToClosedState() {
          const {
            pswp
          } = this;
          if (this._animateZoom) {
            this._setClosedStateZoomPan(true);
          }
          if (this._animateBgOpacity && pswp.bgOpacity > 0.01 && pswp.bg) {
            this._animateTo(pswp.bg, "opacity", "0");
          }
          if (this._animateRootOpacity && pswp.element) {
            this._animateTo(pswp.element, "opacity", "0");
          }
        }
        /**
         * @private
         * @param {boolean} [animate]
         */
        _setClosedStateZoomPan(animate) {
          if (!this._thumbBounds) return;
          const {
            pswp
          } = this;
          const {
            innerRect
          } = this._thumbBounds;
          const {
            currSlide,
            viewportSize
          } = pswp;
          if (this._croppedZoom && innerRect && this._cropContainer1 && this._cropContainer2) {
            const containerOnePanX = -viewportSize.x + (this._thumbBounds.x - innerRect.x) + innerRect.w;
            const containerOnePanY = -viewportSize.y + (this._thumbBounds.y - innerRect.y) + innerRect.h;
            const containerTwoPanX = viewportSize.x - innerRect.w;
            const containerTwoPanY = viewportSize.y - innerRect.h;
            if (animate) {
              this._animateTo(this._cropContainer1, "transform", toTransformString(containerOnePanX, containerOnePanY));
              this._animateTo(this._cropContainer2, "transform", toTransformString(containerTwoPanX, containerTwoPanY));
            } else {
              setTransform(this._cropContainer1, containerOnePanX, containerOnePanY);
              setTransform(this._cropContainer2, containerTwoPanX, containerTwoPanY);
            }
          }
          if (currSlide) {
            equalizePoints(currSlide.pan, innerRect || this._thumbBounds);
            currSlide.currZoomLevel = this._thumbBounds.w / currSlide.width;
            if (animate) {
              this._animateTo(currSlide.container, "transform", currSlide.getCurrentTransform());
            } else {
              currSlide.applyCurrentZoomPan();
            }
          }
        }
        /**
         * @private
         * @param {HTMLElement} target
         * @param {'transform' | 'opacity'} prop
         * @param {string} propValue
         */
        _animateTo(target, prop, propValue) {
          if (!this._duration) {
            target.style[prop] = propValue;
            return;
          }
          const {
            animations
          } = this.pswp;
          const animProps = {
            duration: this._duration,
            easing: this.pswp.options.easing,
            onComplete: () => {
              if (!animations.activeAnimations.length) {
                this._onAnimationComplete();
              }
            },
            target
          };
          animProps[prop] = propValue;
          animations.startTransition(animProps);
        }
      };
      defaultOptions = {
        allowPanToNext: true,
        spacing: 0.1,
        loop: true,
        pinchToClose: true,
        closeOnVerticalDrag: true,
        hideAnimationDuration: 333,
        showAnimationDuration: 333,
        zoomAnimationDuration: 333,
        escKey: true,
        arrowKeys: true,
        trapFocus: true,
        returnFocus: true,
        maxWidthToAnimate: 4e3,
        clickToCloseNonZoomable: true,
        imageClickAction: "zoom-or-close",
        bgClickAction: "close",
        tapAction: "toggle-controls",
        doubleTapAction: "zoom",
        indexIndicatorSep: " / ",
        preloaderDelay: 2e3,
        bgOpacity: 0.8,
        index: 0,
        errorMsg: "The image cannot be loaded",
        preload: [1, 2],
        easing: "cubic-bezier(.4,0,.22,1)"
      };
      PhotoSwipe = class extends PhotoSwipeBase {
        /**
         * @param {PhotoSwipeOptions} [options]
         */
        constructor(options) {
          super();
          this.options = this._prepareOptions(options || {});
          this.offset = {
            x: 0,
            y: 0
          };
          this._prevViewportSize = {
            x: 0,
            y: 0
          };
          this.viewportSize = {
            x: 0,
            y: 0
          };
          this.bgOpacity = 1;
          this.currIndex = 0;
          this.potentialIndex = 0;
          this.isOpen = false;
          this.isDestroying = false;
          this.hasMouse = false;
          this._initialItemData = {};
          this._initialThumbBounds = void 0;
          this.topBar = void 0;
          this.element = void 0;
          this.template = void 0;
          this.container = void 0;
          this.scrollWrap = void 0;
          this.currSlide = void 0;
          this.events = new DOMEvents();
          this.animations = new Animations();
          this.mainScroll = new MainScroll(this);
          this.gestures = new Gestures(this);
          this.opener = new Opener(this);
          this.keyboard = new Keyboard(this);
          this.contentLoader = new ContentLoader(this);
        }
        /** @returns {boolean} */
        init() {
          if (this.isOpen || this.isDestroying) {
            return false;
          }
          this.isOpen = true;
          this.dispatch("init");
          this.dispatch("beforeOpen");
          this._createMainStructure();
          let rootClasses = "pswp--open";
          if (this.gestures.supportsTouch) {
            rootClasses += " pswp--touch";
          }
          if (this.options.mainClass) {
            rootClasses += " " + this.options.mainClass;
          }
          if (this.element) {
            this.element.className += " " + rootClasses;
          }
          this.currIndex = this.options.index || 0;
          this.potentialIndex = this.currIndex;
          this.dispatch("firstUpdate");
          this.scrollWheel = new ScrollWheel(this);
          if (Number.isNaN(this.currIndex) || this.currIndex < 0 || this.currIndex >= this.getNumItems()) {
            this.currIndex = 0;
          }
          if (!this.gestures.supportsTouch) {
            this.mouseDetected();
          }
          this.updateSize();
          this.offset.y = window.pageYOffset;
          this._initialItemData = this.getItemData(this.currIndex);
          this.dispatch("gettingData", {
            index: this.currIndex,
            data: this._initialItemData,
            slide: void 0
          });
          this._initialThumbBounds = this.getThumbBounds();
          this.dispatch("initialLayout");
          this.on("openingAnimationEnd", () => {
            const {
              itemHolders
            } = this.mainScroll;
            if (itemHolders[0]) {
              itemHolders[0].el.style.display = "block";
              this.setContent(itemHolders[0], this.currIndex - 1);
            }
            if (itemHolders[2]) {
              itemHolders[2].el.style.display = "block";
              this.setContent(itemHolders[2], this.currIndex + 1);
            }
            this.appendHeavy();
            this.contentLoader.updateLazy();
            this.events.add(window, "resize", this._handlePageResize.bind(this));
            this.events.add(window, "scroll", this._updatePageScrollOffset.bind(this));
            this.dispatch("bindEvents");
          });
          if (this.mainScroll.itemHolders[1]) {
            this.setContent(this.mainScroll.itemHolders[1], this.currIndex);
          }
          this.dispatch("change");
          this.opener.open();
          this.dispatch("afterInit");
          return true;
        }
        /**
         * Get looped slide index
         * (for example, -1 will return the last slide)
         *
         * @param {number} index
         * @returns {number}
         */
        getLoopedIndex(index) {
          const numSlides = this.getNumItems();
          if (this.options.loop) {
            if (index > numSlides - 1) {
              index -= numSlides;
            }
            if (index < 0) {
              index += numSlides;
            }
          }
          return clamp(index, 0, numSlides - 1);
        }
        appendHeavy() {
          this.mainScroll.itemHolders.forEach((itemHolder) => {
            var _itemHolder$slide;
            (_itemHolder$slide = itemHolder.slide) === null || _itemHolder$slide === void 0 || _itemHolder$slide.appendHeavy();
          });
        }
        /**
         * Change the slide
         * @param {number} index New index
         */
        goTo(index) {
          this.mainScroll.moveIndexBy(this.getLoopedIndex(index) - this.potentialIndex);
        }
        /**
         * Go to the next slide.
         */
        next() {
          this.goTo(this.potentialIndex + 1);
        }
        /**
         * Go to the previous slide.
         */
        prev() {
          this.goTo(this.potentialIndex - 1);
        }
        /**
         * @see slide/slide.js zoomTo
         *
         * @param {Parameters<Slide['zoomTo']>} args
         */
        zoomTo(...args) {
          var _this$currSlide;
          (_this$currSlide = this.currSlide) === null || _this$currSlide === void 0 || _this$currSlide.zoomTo(...args);
        }
        /**
         * @see slide/slide.js toggleZoom
         */
        toggleZoom() {
          var _this$currSlide2;
          (_this$currSlide2 = this.currSlide) === null || _this$currSlide2 === void 0 || _this$currSlide2.toggleZoom();
        }
        /**
         * Close the gallery.
         * After closing transition ends - destroy it
         */
        close() {
          if (!this.opener.isOpen || this.isDestroying) {
            return;
          }
          this.isDestroying = true;
          this.dispatch("close");
          this.events.removeAll();
          this.opener.close();
        }
        /**
         * Destroys the gallery:
         * - instantly closes the gallery
         * - unbinds events,
         * - cleans intervals and timeouts
         * - removes elements from DOM
         */
        destroy() {
          var _this$element;
          if (!this.isDestroying) {
            this.options.showHideAnimationType = "none";
            this.close();
            return;
          }
          this.dispatch("destroy");
          this._listeners = {};
          if (this.scrollWrap) {
            this.scrollWrap.ontouchmove = null;
            this.scrollWrap.ontouchend = null;
          }
          (_this$element = this.element) === null || _this$element === void 0 || _this$element.remove();
          this.mainScroll.itemHolders.forEach((itemHolder) => {
            var _itemHolder$slide2;
            (_itemHolder$slide2 = itemHolder.slide) === null || _itemHolder$slide2 === void 0 || _itemHolder$slide2.destroy();
          });
          this.contentLoader.destroy();
          this.events.removeAll();
        }
        /**
         * Refresh/reload content of a slide by its index
         *
         * @param {number} slideIndex
         */
        refreshSlideContent(slideIndex) {
          this.contentLoader.removeByIndex(slideIndex);
          this.mainScroll.itemHolders.forEach((itemHolder, i) => {
            var _this$currSlide$index, _this$currSlide3;
            let potentialHolderIndex = ((_this$currSlide$index = (_this$currSlide3 = this.currSlide) === null || _this$currSlide3 === void 0 ? void 0 : _this$currSlide3.index) !== null && _this$currSlide$index !== void 0 ? _this$currSlide$index : 0) - 1 + i;
            if (this.canLoop()) {
              potentialHolderIndex = this.getLoopedIndex(potentialHolderIndex);
            }
            if (potentialHolderIndex === slideIndex) {
              this.setContent(itemHolder, slideIndex, true);
              if (i === 1) {
                var _itemHolder$slide3;
                this.currSlide = itemHolder.slide;
                (_itemHolder$slide3 = itemHolder.slide) === null || _itemHolder$slide3 === void 0 || _itemHolder$slide3.setIsActive(true);
              }
            }
          });
          this.dispatch("change");
        }
        /**
         * Set slide content
         *
         * @param {ItemHolder} holder mainScroll.itemHolders array item
         * @param {number} index Slide index
         * @param {boolean} [force] If content should be set even if index wasn't changed
         */
        setContent(holder, index, force) {
          if (this.canLoop()) {
            index = this.getLoopedIndex(index);
          }
          if (holder.slide) {
            if (holder.slide.index === index && !force) {
              return;
            }
            holder.slide.destroy();
            holder.slide = void 0;
          }
          if (!this.canLoop() && (index < 0 || index >= this.getNumItems())) {
            return;
          }
          const itemData = this.getItemData(index);
          holder.slide = new Slide(itemData, index, this);
          if (index === this.currIndex) {
            this.currSlide = holder.slide;
          }
          holder.slide.append(holder.el);
        }
        /** @returns {Point} */
        getViewportCenterPoint() {
          return {
            x: this.viewportSize.x / 2,
            y: this.viewportSize.y / 2
          };
        }
        /**
         * Update size of all elements.
         * Executed on init and on page resize.
         *
         * @param {boolean} [force] Update size even if size of viewport was not changed.
         */
        updateSize(force) {
          if (this.isDestroying) {
            return;
          }
          const newViewportSize = getViewportSize(this.options, this);
          if (!force && pointsEqual(newViewportSize, this._prevViewportSize)) {
            return;
          }
          equalizePoints(this._prevViewportSize, newViewportSize);
          this.dispatch("beforeResize");
          equalizePoints(this.viewportSize, this._prevViewportSize);
          this._updatePageScrollOffset();
          this.dispatch("viewportSize");
          this.mainScroll.resize(this.opener.isOpen);
          if (!this.hasMouse && window.matchMedia("(any-hover: hover)").matches) {
            this.mouseDetected();
          }
          this.dispatch("resize");
        }
        /**
         * @param {number} opacity
         */
        applyBgOpacity(opacity) {
          this.bgOpacity = Math.max(opacity, 0);
          if (this.bg) {
            this.bg.style.opacity = String(this.bgOpacity * this.options.bgOpacity);
          }
        }
        /**
         * Whether mouse is detected
         */
        mouseDetected() {
          if (!this.hasMouse) {
            var _this$element2;
            this.hasMouse = true;
            (_this$element2 = this.element) === null || _this$element2 === void 0 || _this$element2.classList.add("pswp--has_mouse");
          }
        }
        /**
         * Page resize event handler
         *
         * @private
         */
        _handlePageResize() {
          this.updateSize();
          if (/iPhone|iPad|iPod/i.test(window.navigator.userAgent)) {
            setTimeout(() => {
              this.updateSize();
            }, 500);
          }
        }
        /**
         * Page scroll offset is used
         * to get correct coordinates
         * relative to PhotoSwipe viewport.
         *
         * @private
         */
        _updatePageScrollOffset() {
          this.setScrollOffset(0, window.pageYOffset);
        }
        /**
         * @param {number} x
         * @param {number} y
         */
        setScrollOffset(x, y) {
          this.offset.x = x;
          this.offset.y = y;
          this.dispatch("updateScrollOffset");
        }
        /**
         * Create main HTML structure of PhotoSwipe,
         * and add it to DOM
         *
         * @private
         */
        _createMainStructure() {
          this.element = createElement("pswp", "div");
          this.element.setAttribute("tabindex", "-1");
          this.element.setAttribute("role", "dialog");
          this.template = this.element;
          this.bg = createElement("pswp__bg", "div", this.element);
          this.scrollWrap = createElement("pswp__scroll-wrap", "section", this.element);
          this.container = createElement("pswp__container", "div", this.scrollWrap);
          this.scrollWrap.setAttribute("aria-roledescription", "carousel");
          this.container.setAttribute("aria-live", "off");
          this.container.setAttribute("id", "pswp__items");
          this.mainScroll.appendHolders();
          this.ui = new UI(this);
          this.ui.init();
          (this.options.appendToEl || document.body).appendChild(this.element);
        }
        /**
         * Get position and dimensions of small thumbnail
         *   {x:,y:,w:}
         *
         * Height is optional (calculated based on the large image)
         *
         * @returns {Bounds | undefined}
         */
        getThumbBounds() {
          return getThumbBounds(this.currIndex, this.currSlide ? this.currSlide.data : this._initialItemData, this);
        }
        /**
         * If the PhotoSwipe can have continuous loop
         * @returns Boolean
         */
        canLoop() {
          return this.options.loop && this.getNumItems() > 2;
        }
        /**
         * @private
         * @param {PhotoSwipeOptions} options
         * @returns {PreparedPhotoSwipeOptions}
         */
        _prepareOptions(options) {
          if (window.matchMedia("(prefers-reduced-motion), (update: slow)").matches) {
            options.showHideAnimationType = "none";
            options.zoomAnimationDuration = 0;
          }
          return {
            ...defaultOptions,
            ...options
          };
        }
      };
    }
  });

  // ../../phoenix_kit_photos/assets/node_modules/photoswipe/dist/photoswipe.css
  var photoswipe_default;
  var init_photoswipe = __esm({
    "../../phoenix_kit_photos/assets/node_modules/photoswipe/dist/photoswipe.css"() {
      photoswipe_default = '/*! PhotoSwipe main CSS by Dmytro Semenov | photoswipe.com */\r\n\r\n.pswp {\r\n  --pswp-bg: #000;\r\n  --pswp-placeholder-bg: #222;\r\n  \r\n\r\n  --pswp-root-z-index: 100000;\r\n  \r\n  --pswp-preloader-color: rgba(79, 79, 79, 0.4);\r\n  --pswp-preloader-color-secondary: rgba(255, 255, 255, 0.9);\r\n  \r\n  /* defined via js:\r\n  --pswp-transition-duration: 333ms; */\r\n  \r\n  --pswp-icon-color: #fff;\r\n  --pswp-icon-color-secondary: #4f4f4f;\r\n  --pswp-icon-stroke-color: #4f4f4f;\r\n  --pswp-icon-stroke-width: 2px;\r\n\r\n  --pswp-error-text-color: var(--pswp-icon-color);\r\n}\r\n\r\n\r\n/*\r\n	Styles for basic PhotoSwipe (pswp) functionality (sliding area, open/close transitions)\r\n*/\r\n\r\n.pswp {\r\n	position: fixed;\r\n	top: 0;\r\n	left: 0;\r\n	width: 100%;\r\n	height: 100%;\r\n	z-index: var(--pswp-root-z-index);\r\n	display: none;\r\n	touch-action: none;\r\n	outline: 0;\r\n	opacity: 0.003;\r\n	contain: layout style size;\r\n	-webkit-tap-highlight-color: rgba(0, 0, 0, 0);\r\n}\r\n\r\n/* Prevents focus outline on the root element,\r\n  (it may be focused initially) */\r\n.pswp:focus {\r\n  outline: 0;\r\n}\r\n\r\n.pswp * {\r\n  box-sizing: border-box;\r\n}\r\n\r\n.pswp img {\r\n  max-width: none;\r\n}\r\n\r\n.pswp--open {\r\n	display: block;\r\n}\r\n\r\n.pswp,\r\n.pswp__bg {\r\n	transform: translateZ(0);\r\n	will-change: opacity;\r\n}\r\n\r\n.pswp__bg {\r\n  opacity: 0.005;\r\n	background: var(--pswp-bg);\r\n}\r\n\r\n.pswp,\r\n.pswp__scroll-wrap {\r\n	overflow: hidden;\r\n}\r\n\r\n.pswp__scroll-wrap,\r\n.pswp__bg,\r\n.pswp__container,\r\n.pswp__item,\r\n.pswp__content,\r\n.pswp__img,\r\n.pswp__zoom-wrap {\r\n	position: absolute;\r\n	top: 0;\r\n	left: 0;\r\n	width: 100%;\r\n	height: 100%;\r\n}\r\n\r\n.pswp__img,\r\n.pswp__zoom-wrap {\r\n	width: auto;\r\n	height: auto;\r\n}\r\n\r\n.pswp--click-to-zoom.pswp--zoom-allowed .pswp__img {\r\n	cursor: -webkit-zoom-in;\r\n	cursor: -moz-zoom-in;\r\n	cursor: zoom-in;\r\n}\r\n\r\n.pswp--click-to-zoom.pswp--zoomed-in .pswp__img {\r\n	cursor: move;\r\n	cursor: -webkit-grab;\r\n	cursor: -moz-grab;\r\n	cursor: grab;\r\n}\r\n\r\n.pswp--click-to-zoom.pswp--zoomed-in .pswp__img:active {\r\n  cursor: -webkit-grabbing;\r\n  cursor: -moz-grabbing;\r\n  cursor: grabbing;\r\n}\r\n\r\n/* :active to override grabbing cursor */\r\n.pswp--no-mouse-drag.pswp--zoomed-in .pswp__img,\r\n.pswp--no-mouse-drag.pswp--zoomed-in .pswp__img:active,\r\n.pswp__img {\r\n	cursor: -webkit-zoom-out;\r\n	cursor: -moz-zoom-out;\r\n	cursor: zoom-out;\r\n}\r\n\r\n\r\n/* Prevent selection and tap highlights */\r\n.pswp__container,\r\n.pswp__img,\r\n.pswp__button,\r\n.pswp__counter {\r\n	-webkit-user-select: none;\r\n	-moz-user-select: none;\r\n	-ms-user-select: none;\r\n	user-select: none;\r\n}\r\n\r\n.pswp__item {\r\n	/* z-index for fade transition */\r\n	z-index: 1;\r\n	overflow: hidden;\r\n}\r\n\r\n.pswp__hidden {\r\n	display: none !important;\r\n}\r\n\r\n/* Allow to click through pswp__content element, but not its children */\r\n.pswp__content {\r\n  pointer-events: none;\r\n}\r\n.pswp__content > * {\r\n  pointer-events: auto;\r\n}\r\n\r\n\r\n/*\r\n\r\n  PhotoSwipe UI\r\n\r\n*/\r\n\r\n/*\r\n	Error message appears when image is not loaded\r\n	(JS option errorMsg controls markup)\r\n*/\r\n.pswp__error-msg-container {\r\n  display: grid;\r\n}\r\n.pswp__error-msg {\r\n	margin: auto;\r\n	font-size: 1em;\r\n	line-height: 1;\r\n	color: var(--pswp-error-text-color);\r\n}\r\n\r\n/*\r\nclass pswp__hide-on-close is applied to elements that\r\nshould hide (for example fade out) when PhotoSwipe is closed\r\nand show (for example fade in) when PhotoSwipe is opened\r\n */\r\n.pswp .pswp__hide-on-close {\r\n	opacity: 0.005;\r\n	will-change: opacity;\r\n	transition: opacity var(--pswp-transition-duration) cubic-bezier(0.4, 0, 0.22, 1);\r\n	z-index: 10; /* always overlap slide content */\r\n	pointer-events: none; /* hidden elements should not be clickable */\r\n}\r\n\r\n/* class pswp--ui-visible is added when opening or closing transition starts */\r\n.pswp--ui-visible .pswp__hide-on-close {\r\n	opacity: 1;\r\n	pointer-events: auto;\r\n}\r\n\r\n/* <button> styles, including css reset */\r\n.pswp__button {\r\n	position: relative;\r\n	display: block;\r\n	width: 50px;\r\n	height: 60px;\r\n	padding: 0;\r\n	margin: 0;\r\n	overflow: hidden;\r\n	cursor: pointer;\r\n	background: none;\r\n	border: 0;\r\n	box-shadow: none;\r\n	opacity: 0.85;\r\n	-webkit-appearance: none;\r\n	-webkit-touch-callout: none;\r\n}\r\n\r\n.pswp__button:hover,\r\n.pswp__button:active,\r\n.pswp__button:focus {\r\n  transition: none;\r\n  padding: 0;\r\n  background: none;\r\n  border: 0;\r\n  box-shadow: none;\r\n  opacity: 1;\r\n}\r\n\r\n.pswp__button:disabled {\r\n  opacity: 0.3;\r\n  cursor: auto;\r\n}\r\n\r\n.pswp__icn {\r\n  fill: var(--pswp-icon-color);\r\n  color: var(--pswp-icon-color-secondary);\r\n}\r\n\r\n.pswp__icn {\r\n  position: absolute;\r\n  top: 14px;\r\n  left: 9px;\r\n  width: 32px;\r\n  height: 32px;\r\n  overflow: hidden;\r\n  pointer-events: none;\r\n}\r\n\r\n.pswp__icn-shadow {\r\n  stroke: var(--pswp-icon-stroke-color);\r\n  stroke-width: var(--pswp-icon-stroke-width);\r\n  fill: none;\r\n}\r\n\r\n.pswp__icn:focus {\r\n	outline: 0;\r\n}\r\n\r\n/*\r\n	div element that matches size of large image,\r\n	large image loads on top of it,\r\n	used when msrc is not provided\r\n*/\r\ndiv.pswp__img--placeholder,\r\n.pswp__img--with-bg {\r\n	background: var(--pswp-placeholder-bg);\r\n}\r\n\r\n.pswp__top-bar {\r\n	position: absolute;\r\n	left: 0;\r\n	top: 0;\r\n	width: 100%;\r\n	height: 60px;\r\n	display: flex;\r\n  flex-direction: row;\r\n  justify-content: flex-end;\r\n	z-index: 10;\r\n\r\n	/* allow events to pass through top bar itself */\r\n	pointer-events: none !important;\r\n}\r\n.pswp__top-bar > * {\r\n  pointer-events: auto;\r\n  /* this makes transition significantly more smooth,\r\n     even though inner elements are not animated */\r\n  will-change: opacity;\r\n}\r\n\r\n\r\n/*\r\n\r\n  Close button\r\n\r\n*/\r\n.pswp__button--close {\r\n  margin-right: 6px;\r\n}\r\n\r\n\r\n/*\r\n\r\n  Arrow buttons\r\n\r\n*/\r\n.pswp__button--arrow {\r\n  position: absolute;\r\n  top: 0;\r\n  width: 75px;\r\n  height: 100px;\r\n  top: 50%;\r\n  margin-top: -50px;\r\n}\r\n\r\n.pswp__button--arrow:disabled {\r\n  display: none;\r\n  cursor: default;\r\n}\r\n\r\n.pswp__button--arrow .pswp__icn {\r\n  top: 50%;\r\n  margin-top: -30px;\r\n  width: 60px;\r\n  height: 60px;\r\n  background: none;\r\n  border-radius: 0;\r\n}\r\n\r\n.pswp--one-slide .pswp__button--arrow {\r\n  display: none;\r\n}\r\n\r\n/* hide arrows on touch screens */\r\n.pswp--touch .pswp__button--arrow {\r\n  visibility: hidden;\r\n}\r\n\r\n/* show arrows only after mouse was used */\r\n.pswp--has_mouse .pswp__button--arrow {\r\n  visibility: visible;\r\n}\r\n\r\n.pswp__button--arrow--prev {\r\n  right: auto;\r\n  left: 0px;\r\n}\r\n\r\n.pswp__button--arrow--next {\r\n  right: 0px;\r\n}\r\n.pswp__button--arrow--next .pswp__icn {\r\n  left: auto;\r\n  right: 14px;\r\n  /* flip horizontally */\r\n  transform: scale(-1, 1);\r\n}\r\n\r\n/*\r\n\r\n  Zoom button\r\n\r\n*/\r\n.pswp__button--zoom {\r\n  display: none;\r\n}\r\n\r\n.pswp--zoom-allowed .pswp__button--zoom {\r\n  display: block;\r\n}\r\n\r\n/* "+" => "-" */\r\n.pswp--zoomed-in .pswp__zoom-icn-bar-v {\r\n  display: none;\r\n}\r\n\r\n\r\n/*\r\n\r\n  Loading indicator\r\n\r\n*/\r\n.pswp__preloader {\r\n  position: relative;\r\n  overflow: hidden;\r\n  width: 50px;\r\n  height: 60px;\r\n  margin-right: auto;\r\n}\r\n\r\n.pswp__preloader .pswp__icn {\r\n  opacity: 0;\r\n  transition: opacity 0.2s linear;\r\n  animation: pswp-clockwise 600ms linear infinite;\r\n}\r\n\r\n.pswp__preloader--active .pswp__icn {\r\n  opacity: 0.85;\r\n}\r\n\r\n@keyframes pswp-clockwise {\r\n  0% { transform: rotate(0deg); }\r\n  100% { transform: rotate(360deg); }\r\n}\r\n\r\n\r\n/*\r\n\r\n  "1 of 10" counter\r\n\r\n*/\r\n.pswp__counter {\r\n  height: 30px;\r\n  margin-top: 15px;\r\n  margin-inline-start: 20px;\r\n  font-size: 14px;\r\n  line-height: 30px;\r\n  color: var(--pswp-icon-color);\r\n  text-shadow: 1px 1px 3px var(--pswp-icon-color-secondary);\r\n  opacity: 0.85;\r\n}\r\n\r\n.pswp--one-slide .pswp__counter {\r\n  display: none;\r\n}\r\n';
    }
  });

  // js/viewer/video.js
  function defaultEnv() {
    const probe = document.createElement("video");
    return {
      hdrScreen: !!(window.matchMedia && window.matchMedia("(dynamic-range: high)").matches),
      canPlay: (type) => !!type && probe.canPlayType(type) !== ""
    };
  }
  function addStyle(id, css) {
    if (document.getElementById(id)) return;
    const style = document.createElement("style");
    style.id = id;
    style.textContent = css;
    document.head.appendChild(style);
  }
  var VideoController, SHARED_CSS;
  var init_video = __esm({
    "js/viewer/video.js"() {
      init_slides();
      VideoController = class {
        constructor(env) {
          this.env = env || defaultEnv();
          this.muted = true;
        }
        /** A <video> for `slide` (`poster`, `sources`), not yet loading anything. */
        build(slide) {
          const video = document.createElement("video");
          video.className = "pk-pager__video";
          video.controls = true;
          video.playsInline = true;
          video.setAttribute("playsinline", "");
          video.preload = "none";
          video.muted = this.muted;
          if (slide.poster) video.poster = slide.poster;
          video.pkSources = slide.sources || [];
          video.pkTried = null;
          video.addEventListener("volumechange", () => {
            this.muted = video.muted;
          });
          video.addEventListener("error", () => this.next(video));
          return video;
        }
        /** The slide is on screen: choose a file the first time, then play (muted until the person unmutes). */
        play(video) {
          if (!video) return;
          if (video.pkTried === null) {
            const first = chooseSource(video.pkSources, this.env);
            video.pkTried = first ? [first.url] : [];
            if (first) {
              video.src = first.url;
              video.preload = "auto";
            }
          }
          video.muted = this.muted;
          this.start(video);
        }
        pause(video) {
          if (video) video.pause();
        }
        // The file failed (a codec this browser lacks, a dead link): try the next listed one.
        next(video) {
          if (video.pkTried === null) return;
          const source = video.pkSources.find((s) => !video.pkTried.includes(s.url));
          if (!source) return;
          video.pkTried.push(source.url);
          video.src = source.url;
          video.load();
          this.start(video);
        }
        start(video) {
          const attempt = video.play();
          if (attempt && attempt.catch) attempt.catch(() => {
          });
        }
      };
      SHARED_CSS = `
.pk-pager__video { display: block; width: 100%; height: 100%; object-fit: contain; background: #000; }
.pk-pager__wait { width: 100%; height: 100%; display: grid; place-items: center; }
.pk-pager__wait::after { content: ""; width: 28px; height: 28px; border-radius: 50%;
  border: 3px solid rgba(255,255,255,.25); border-top-color: #fff; animation: pk-pager-spin .8s linear infinite; }
@keyframes pk-pager-spin { to { transform: rotate(360deg); } }
`;
    }
  });

  // js/viewer/photoswipe.js
  var photoswipe_exports = {};
  __export(photoswipe_exports, {
    PhotoSwipeEngine: () => PhotoSwipeEngine
  });
  var INFO_ICON, CONTROLS_STRIP, PhotoSwipeEngine;
  var init_photoswipe2 = __esm({
    "js/viewer/photoswipe.js"() {
      init_photoswipe_esm();
      init_photoswipe();
      init_engine();
      init_video();
      INFO_ICON = '<svg aria-hidden="true" class="pswp__icn" viewBox="0 0 32 32" width="32" height="32"><circle cx="16" cy="16" r="9" fill="none" stroke="#fff" stroke-width="2"/><path d="M16 15v6.5M16 10.8v.4" stroke="#fff" stroke-width="2.4" stroke-linecap="round"/></svg>';
      CONTROLS_STRIP = 72;
      PhotoSwipeEngine = class {
        constructor(host) {
          this.store = host.store;
          this.thumbOf = host.thumbOf;
          this.tileImage = host.tileImage;
          this.video = host.video;
          this.onInfo = host.onInfo;
          this.onChange = host.onChange;
          this.onClose = host.onClose;
          this.pswp = null;
        }
        get isOpen() {
          return this.pswp !== null;
        }
        get index() {
          return this.pswp ? this.pswp.currIndex : -1;
        }
        open(index) {
          if (this.pswp) return;
          addStyle("pk-photoswipe-css", photoswipe_default + SHARED_CSS);
          const pswp = new PhotoSwipe({
            dataSource: [],
            index,
            loop: false,
            bgOpacity: 1,
            preload: [1, 2],
            // Grid thumbnails are cropped; the viewer uses the full frame from the start.
            showHideAnimationType: "fade",
            clickToCloseNonZoomable: false,
            wheelToZoom: true,
            initialZoomLevel: "fit",
            // A double tap goes three times closer than "fit", but never past the
            // rendition's own pixels (1 is its natural size): beyond that it only blurs.
            secondaryZoomLevel: (zoom) => Math.min(zoom.fit * 3, 1),
            maxZoomLevel: 1.5,
            closeTitle: "Close",
            zoomTitle: "Zoom",
            arrowPrevTitle: "Previous",
            arrowNextTitle: "Next",
            errorMsg: "This could not be loaded"
          });
          this.pswp = pswp;
          pswp.addFilter("numItems", () => this.store.total);
          pswp.addFilter("itemData", (_data, i) => this.itemData(i));
          pswp.addFilter("thumbEl", (_el, _data, i) => this.tileImage(i) || void 0);
          pswp.addFilter("placeholderSrc", (_src, content) => content.data.msrc || false);
          pswp.addFilter("useContentPlaceholder", (use, content) => use || content.data.type === "video");
          pswp.on("uiRegister", () => {
            pswp.ui.registerElement({
              name: "info",
              order: 8,
              isButton: true,
              appendTo: "bar",
              html: INFO_ICON,
              title: "Details",
              ariaLabel: "Details",
              onClick: () => {
                const slide = this.store.get(pswp.currIndex);
                if (slide) this.onInfo(slide.id);
              }
            });
          });
          pswp.on("contentAppend", ({ content }) => this.buildVideo(content));
          pswp.on("contentActivate", ({ content }) => {
            if (pswp.opener.isOpen) this.play(content);
          });
          pswp.on("contentDeactivate", ({ content }) => this.pause(content));
          pswp.on("openingAnimationEnd", () => {
            if (pswp.currSlide) this.play(pswp.currSlide.content);
          });
          pswp.on("pointerDown", (event) => this.keepControlsUsable(event));
          pswp.on("keydown", (event) => {
            if (dialogOpen()) event.preventDefault();
          });
          pswp.on("change", () => this.onChange(pswp.currIndex));
          pswp.on("destroy", () => {
            this.pswp = null;
            this.onClose();
          });
          pswp.init();
        }
        close() {
          if (this.pswp) this.pswp.close();
        }
        /** Turn to `index` without the slide animation of a swipe. */
        goTo(index) {
          if (this.pswp) this.pswp.goTo(index);
        }
        /** Slides at `indices` have arrived: show them where a waiting slide was. */
        refresh(indices) {
          if (!this.pswp) return;
          const here = this.pswp.currIndex;
          for (const index of indices) {
            if (Math.abs(index - here) <= 2) this.pswp.refreshSlideContent(index);
          }
        }
        destroy() {
          if (this.pswp) this.pswp.destroy();
        }
        itemData(index) {
          const slide = this.store.get(index);
          if (!slide) {
            return {
              type: "html",
              html: '<div class="pk-pager__wait" aria-busy="true"></div>',
              width: 1200,
              height: 800
            };
          }
          const msrc = this.thumbOf(slide.id) || slide.poster || void 0;
          if (slide.kind === "video") {
            return {
              id: slide.id,
              type: "video",
              html: "",
              width: slide.w,
              height: slide.h,
              msrc: slide.poster || msrc,
              poster: slide.poster,
              sources: slide.sources,
              thumbCropped: true
            };
          }
          return {
            id: slide.id,
            type: "image",
            src: slide.src || slide.preview || "",
            // Never stretch the grid crop into the full-frame image's dimensions.
            msrc: slide.preview || void 0,
            width: slide.w,
            height: slide.h,
            alt: "",
            thumbCropped: true
          };
        }
        // --- video -----------------------------------------------------------
        buildVideo(content) {
          if (content.data.type !== "video" || content.video || !content.element) return;
          content.video = this.video.build(content.data);
          content.element.appendChild(content.video);
        }
        play(content) {
          if (content && content.video) this.video.play(content.video);
        }
        pause(content) {
          if (content && content.video) this.video.pause(content.video);
        }
        // A touch on a video's own control bar is for the controls, not for a swipe.
        keepControlsUsable(event) {
          const target = event.originalEvent && event.originalEvent.target;
          if (!target || target.tagName !== "VIDEO") return;
          const rect = target.getBoundingClientRect();
          if (event.originalEvent.clientY >= rect.bottom - CONTROLS_STRIP) event.preventDefault();
        }
      };
      __publicField(PhotoSwipeEngine, "id", "photoswipe");
      __publicField(PhotoSwipeEngine, "label", "PhotoSwipe");
    }
  });

  // js/viewer/snap.js
  var snap_exports = {};
  __export(snap_exports, {
    SnapEngine: () => SnapEngine
  });
  var CSS2, INFO_ICON2, CLOSE_ICON, SETTLE_MS, FADE_MS, SnapEngine;
  var init_snap = __esm({
    "js/viewer/snap.js"() {
      init_engine();
      init_video();
      CSS2 = `
.pk-snap { position: fixed; inset: 0; z-index: 100000; background: #000; color: #fff;
  opacity: 0; transition: opacity .18s ease; touch-action: pan-x; overscroll-behavior: contain; }
.pk-snap[data-open] { opacity: 1; }
.pk-snap__track { position: absolute; inset: 0; display: flex; overflow-x: auto; overflow-y: hidden;
  scroll-snap-type: x mandatory; scrollbar-width: none; overscroll-behavior-x: contain; -webkit-overflow-scrolling: touch; }
.pk-snap__track::-webkit-scrollbar { display: none; }
.pk-snap__page { flex: 0 0 100%; height: 100%; scroll-snap-align: center; scroll-snap-stop: always;
  display: grid; place-items: center; overflow: hidden; }
.pk-snap__page img { max-width: 100%; max-height: 100%; object-fit: contain; user-select: none; -webkit-user-drag: none; }
.pk-snap__bar { position: absolute; top: 0; left: 0; right: 0; z-index: 2; display: flex; align-items: center; gap: 4px;
  padding: max(8px, env(safe-area-inset-top)) 12px 16px; background: linear-gradient(rgba(0,0,0,.55), transparent); pointer-events: none; }
.pk-snap__bar > * { pointer-events: auto; }
.pk-snap__count { margin-right: auto; font: 14px system-ui, sans-serif; text-shadow: 0 0 4px #000; }
.pk-snap__button { width: 44px; height: 44px; display: grid; place-items: center; border: 0; background: none; color: #fff; cursor: pointer; }
`;
      INFO_ICON2 = '<svg aria-hidden="true" viewBox="0 0 32 32" width="32" height="32"><circle cx="16" cy="16" r="9" fill="none" stroke="#fff" stroke-width="2"/><path d="M16 15v6.5M16 10.8v.4" stroke="#fff" stroke-width="2.4" stroke-linecap="round"/></svg>';
      CLOSE_ICON = '<svg aria-hidden="true" viewBox="0 0 32 32" width="32" height="32"><path d="M9 9l14 14M23 9L9 23" stroke="#fff" stroke-width="2.4" stroke-linecap="round"/></svg>';
      SETTLE_MS = 100;
      FADE_MS = 180;
      SnapEngine = class {
        constructor(host) {
          this.host = host;
          this.store = host.store;
          this.video = host.video;
          this.root = null;
          this.track = null;
          this.pages = [];
          this.current = -1;
          this.settleTimer = null;
          this.closing = false;
        }
        get isOpen() {
          return this.root !== null;
        }
        get index() {
          return this.current;
        }
        open(index) {
          if (this.root) return;
          addStyle("pk-snap-css", CSS2 + SHARED_CSS);
          const root = document.createElement("div");
          root.className = "pk-snap";
          root.setAttribute("role", "dialog");
          root.setAttribute("aria-modal", "true");
          root.innerHTML = `<div class="pk-snap__bar"><span class="pk-snap__count"></span><button type="button" class="pk-snap__button pk-snap__info" aria-label="Details">${INFO_ICON2}</button><button type="button" class="pk-snap__button pk-snap__close" aria-label="Close">${CLOSE_ICON}</button></div><div class="pk-snap__track"></div>`;
          this.root = root;
          this.track = root.querySelector(".pk-snap__track");
          this.count = root.querySelector(".pk-snap__count");
          this.current = index;
          for (let i = 0; i < 3; i++) {
            const page = document.createElement("div");
            page.className = "pk-snap__page";
            this.track.appendChild(page);
          }
          this.pages = [...this.track.children];
          root.querySelector(".pk-snap__close").addEventListener("click", () => this.close());
          root.querySelector(".pk-snap__info").addEventListener("click", () => {
            const slide = this.store.get(this.current);
            if (slide) this.host.onInfo(slide.id);
          });
          this.track.addEventListener("scroll", () => this.onScroll(), { passive: true });
          this.track.addEventListener("scrollend", () => {
            clearTimeout(this.settleTimer);
            this.settle();
          });
          this.onKey = (event) => this.keydown(event);
          this.onResize = () => this.center();
          document.addEventListener("keydown", this.onKey, true);
          window.addEventListener("resize", this.onResize);
          this.previousOverflow = document.documentElement.style.overflow;
          document.documentElement.style.overflow = "hidden";
          document.body.appendChild(root);
          this.fill();
          this.center();
          this.showCount();
          requestAnimationFrame(() => {
            root.setAttribute("data-open", "");
            this.activate();
          });
        }
        close() {
          if (!this.root || this.closing) return;
          this.closing = true;
          this.pauseAll();
          this.root.removeAttribute("data-open");
          setTimeout(() => this.destroy(), FADE_MS);
        }
        destroy() {
          if (!this.root) return;
          clearTimeout(this.settleTimer);
          document.removeEventListener("keydown", this.onKey, true);
          window.removeEventListener("resize", this.onResize);
          document.documentElement.style.overflow = this.previousOverflow || "";
          this.pauseAll();
          this.root.remove();
          this.root = this.track = null;
          this.pages = [];
          this.closing = false;
          this.host.onClose();
        }
        /** Slides at `indices` have arrived: draw them where a waiting page was. */
        refresh(indices) {
          if (!this.root) return;
          for (const index of indices) {
            const offset = index - this.current;
            if (offset < -1 || offset > 1) continue;
            const page = this.pages[offset + 1];
            if (page.dataset.state === "wait") this.draw(page, index);
          }
        }
        // --- pages -----------------------------------------------------------
        fill() {
          this.pages.forEach((page, i) => this.draw(page, this.current + i - 1));
        }
        draw(page, index) {
          this.pauseIn(page);
          page.replaceChildren();
          delete page.video;
          if (index < 0 || index >= this.store.total) {
            page.dataset.state = "empty";
            return;
          }
          const slide = this.store.get(index);
          if (!slide) {
            page.dataset.state = "wait";
            const wait = document.createElement("div");
            wait.className = "pk-pager__wait";
            wait.setAttribute("aria-busy", "true");
            page.appendChild(wait);
            return;
          }
          page.dataset.state = "ready";
          if (slide.kind === "video") {
            page.video = this.video.build(slide);
            page.appendChild(page.video);
          } else {
            const img = document.createElement("img");
            img.alt = "";
            img.draggable = false;
            img.src = slide.src || this.host.thumbOf(slide.id) || "";
            page.appendChild(img);
          }
        }
        center() {
          if (this.track) this.track.scrollLeft = this.track.clientWidth;
        }
        showCount() {
          this.count.textContent = `${this.current + 1} / ${this.store.total}`;
        }
        // --- paging ----------------------------------------------------------
        onScroll() {
          clearTimeout(this.settleTimer);
          this.settleTimer = setTimeout(() => this.settle(), SETTLE_MS);
        }
        // The scrolling stopped on a page: if it is not the middle one, the page turned.
        settle() {
          if (!this.track) return;
          const width = this.track.clientWidth;
          if (width === 0) return;
          const page = Math.round(this.track.scrollLeft / width);
          if (page === 1) return;
          const target = this.current + (page - 1);
          if (target < 0 || target >= this.store.total) {
            this.track.scrollTo({ left: width, behavior: "smooth" });
            return;
          }
          this.turn(page === 2 ? 1 : -1);
        }
        turn(direction) {
          this.pauseIn(this.pages[1]);
          this.current += direction;
          if (direction > 0) {
            const gone = this.pages.shift();
            this.track.appendChild(gone);
            this.pages.push(gone);
            this.draw(gone, this.current + 1);
          } else {
            const gone = this.pages.pop();
            this.track.insertBefore(gone, this.track.firstChild);
            this.pages.unshift(gone);
            this.draw(gone, this.current - 1);
          }
          this.center();
          this.showCount();
          this.activate();
          this.host.onChange(this.current);
        }
        activate() {
          const page = this.pages[1];
          if (page && page.video) this.video.play(page.video);
        }
        pauseIn(page) {
          if (page && page.video) this.video.pause(page.video);
        }
        pauseAll() {
          this.pages.forEach((page) => this.pauseIn(page));
        }
        keydown(event) {
          if (dialogOpen()) return;
          if (event.key === "Escape") {
            event.preventDefault();
            event.stopPropagation();
            this.close();
          } else if (event.key === "ArrowRight" || event.key === "ArrowLeft") {
            event.preventDefault();
            const width = this.track.clientWidth;
            this.track.scrollTo({ left: event.key === "ArrowRight" ? width * 2 : 0, behavior: "smooth" });
          }
        }
      };
      __publicField(SnapEngine, "id", "snap");
      __publicField(SnapEngine, "label", "Scroll-snap (basic)");
    }
  });

  // js/index.js
  var index_exports = {};
  __export(index_exports, {
    PhotoTimeline: () => PhotoTimeline,
    PhotoUploader: () => PhotoUploader
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
  function buildOffsets(sections, measure, start = 0) {
    const offsets = new Array(sections.length + 1);
    let acc = start;
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

  // js/layouts.js
  var STYLES = {
    grid: { aspects: false, crop: true },
    rows: { aspects: true, crop: false },
    columns: { aspects: true, crop: false },
    mosaic: { aspects: true, crop: true },
    whole: { aspects: true, crop: false },
    feed: { aspects: true, crop: false },
    prints: { aspects: false, crop: true },
    film: { aspects: false, crop: true },
    honeycomb: { aspects: false, crop: true },
    details: { aspects: false, crop: true }
  };
  var STYLE_IDS = Object.keys(STYLES);
  var DEFAULT_STYLE = "grid";
  var OVERSCAN = 240;
  var ASPECT_LOW = Math.log(1 / 8);
  var ASPECT_SPAN = Math.log(8) - ASPECT_LOW;
  var ASPECT_TABLE = Float32Array.from({ length: 256 }, (_, byte) => Math.exp(ASPECT_LOW + byte / 255 * ASPECT_SPAN));
  function decodeAspects(base64) {
    const bytes = atob(base64 || "");
    const aspects = new Float32Array(bytes.length);
    for (let i = 0; i < bytes.length; i++) aspects[i] = ASPECT_TABLE[bytes.charCodeAt(i)];
    return aspects;
  }
  var Grid = class {
    constructor({ count, columns: columns2, tileW, tileH, gapX, gapY, header, left = 0, stagger = 0 }) {
      Object.assign(this, { count, columns: columns2, tileW, tileH, gapX, gapY, header, left, stagger });
      this.rows = count > 0 ? Math.ceil(count / columns2) : 0;
      this.height = count > 0 ? header + this.rows * tileH + (this.rows - 1) * gapY : header;
    }
    rect(index) {
      const row = Math.floor(index / this.columns);
      const col = index % this.columns;
      return {
        x: this.left + col * (this.tileW + this.gapX) + (row % 2 ? this.stagger : 0),
        y: this.header + row * (this.tileH + this.gapY),
        w: this.tileW,
        h: this.tileH
      };
    }
    /** The tiles between two heights measured from the top of the section, with a row to spare. */
    range(top, bottom) {
      const stride = this.tileH + this.gapY;
      const firstRow = Math.max(0, Math.floor((top - this.header) / stride) - 1);
      const lastRow = Math.ceil((bottom - this.header) / stride) + 1;
      const lastIndex = Math.max(0, this.count - 1);
      if (this.count <= 0 || lastRow < 0 || firstRow * this.columns > lastIndex) return { first: 0, last: -1 };
      return {
        first: Math.min(lastIndex, firstRow * this.columns),
        last: Math.min(lastIndex, (lastRow + 1) * this.columns - 1)
      };
    }
    /** A place in the section (px from its top) as a tile number and how far into its row. */
    anchor(delta) {
      const row = Math.max(0, delta - this.header) / (this.tileH + this.gapY);
      const wholeRow = Math.floor(row + 1e-9);
      return { item: wholeRow * this.columns, fraction: Math.max(0, row - wholeRow) };
    }
    /** Back again: px below the section's header for a tile number and fraction. */
    contentY(item, fraction = 0) {
      return (Math.floor(item / this.columns) + fraction) * (this.tileH + this.gapY);
    }
    /** The bookmark's place: the gap before the first complete row. */
    mark(item, fraction = 0) {
      const row = Math.min(this.rows - 1, Math.ceil(item / this.columns + fraction - 1e-9));
      return this.header + Math.max(0, row) * (this.tileH + this.gapY) - (row > 0 ? this.gapY / 2 : 0);
    }
    /** The tile at a point of the section, or the nearest one. */
    hit(x, y) {
      if (this.count <= 0) return -1;
      const row = Math.max(0, Math.floor((y - this.header) / (this.tileH + this.gapY)));
      const shift = this.left + (row % 2 ? this.stagger : 0);
      const col = Math.min(this.columns - 1, Math.max(0, Math.floor((x - shift) / (this.tileW + this.gapX))));
      return Math.min(this.count - 1, row * this.columns + col);
    }
  };
  var Packed = class {
    constructor(rects, count, height, header, gapY) {
      Object.assign(this, { rects, count, height, header, gapY });
      this.bottoms = new Float32Array(count);
      this.tops = new Float32Array(count);
      let bottom = 0;
      for (let i = 0; i < count; i++) {
        bottom = Math.max(bottom, rects[i * 4 + 1] + rects[i * 4 + 3]);
        this.bottoms[i] = bottom;
      }
      let top = Infinity;
      for (let i = count - 1; i >= 0; i--) {
        top = Math.min(top, rects[i * 4 + 1]);
        this.tops[i] = top;
      }
    }
    rect(index) {
      const at = index * 4;
      return { x: this.rects[at], y: this.rects[at + 1], w: this.rects[at + 2], h: this.rects[at + 3] };
    }
    /** The first tile whose running bottom reaches `y`. */
    firstAt(y) {
      let lo = 0;
      let hi = this.count - 1;
      while (lo < hi) {
        const mid = lo + hi >> 1;
        if (this.bottoms[mid] >= y) hi = mid;
        else lo = mid + 1;
      }
      return lo;
    }
    range(top, bottom) {
      if (this.count <= 0) return { first: 0, last: -1 };
      if (this.bottoms[this.count - 1] < top - OVERSCAN) return { first: 0, last: -1 };
      const first = this.firstAt(top - OVERSCAN);
      const end = bottom + OVERSCAN;
      let lo = first;
      let hi = this.count - 1;
      while (lo < hi) {
        const mid = lo + hi + 1 >> 1;
        if (this.tops[mid] <= end) lo = mid;
        else hi = mid - 1;
      }
      return this.tops[first] > end ? { first: 0, last: -1 } : { first, last: lo };
    }
    anchor(delta) {
      if (this.count <= 0) return { item: 0, fraction: 0 };
      const item = this.firstAt(delta);
      const { y, h } = this.rect(item);
      return { item, fraction: Math.min(1, Math.max(0, (delta - y) / (h + this.gapY))) };
    }
    contentY(item, fraction = 0) {
      if (this.count <= 0) return 0;
      const { y, h } = this.rect(Math.min(item, this.count - 1));
      return y - this.header + fraction * (h + this.gapY);
    }
    mark(item, _fraction = 0) {
      if (this.count <= 0) return this.header;
      return this.rect(Math.min(item, this.count - 1)).y - this.gapY / 2;
    }
    hit(x, y) {
      if (this.count <= 0) return -1;
      const { first, last } = this.range(y, y);
      let nearest = -1;
      let best = Infinity;
      for (let i = first; i <= last; i++) {
        const r = this.rect(i);
        const dx = Math.max(r.x - x, 0, x - r.x - r.w);
        const dy = Math.max(r.y - y, 0, y - r.y - r.h);
        const distance2 = dx * dx + dy * dy;
        if (distance2 < best) {
          best = distance2;
          nearest = i;
        }
      }
      return nearest < 0 ? Math.min(this.count - 1, first) : nearest;
    }
  };
  function grid({ count, columns: columns2, cell, gap, header }) {
    return new Grid({ count, columns: columns2, tileW: cell, tileH: cell, gapX: gap, gapY: gap, header });
  }
  function rows({ count, aspectAt, width, cell, gap, header }) {
    const rects = new Float32Array(count * 4);
    const target = Math.max(cell, 48);
    let y = header;
    let start = 0;
    while (start < count) {
      let sum = 0;
      let end = start;
      while (end < count) {
        const next = sum + aspectAt(end);
        const gaps2 = (end - start) * gap;
        const height2 = (width - gaps2) / next;
        if (end > start && Math.abs(height2 - target) > Math.abs((width - (gaps2 - gap)) / sum - target)) break;
        sum = next;
        end++;
        if (height2 <= target) break;
      }
      const gaps = (end - start - 1) * gap;
      const last = end >= count;
      const height = last ? Math.min((width - gaps) / sum, target) : (width - gaps) / sum;
      let x = 0;
      for (let i = start; i < end; i++) {
        const w = aspectAt(i) * height;
        rects.set([x, y, w, height], i * 4);
        x += w + gap;
      }
      y += height + gap;
      start = end;
    }
    return new Packed(rects, count, count > 0 ? y - gap : header, header, gap);
  }
  function columns({ count, aspectAt, columns: columnCount, cell, gap, header }) {
    const rects = new Float32Array(count * 4);
    const bottoms = new Float32Array(columnCount).fill(header);
    for (let i = 0; i < count; i++) {
      let column = 0;
      for (let c = 1; c < columnCount; c++) if (bottoms[c] < bottoms[column] - 0.5) column = c;
      const height = cell / Math.min(2.4, Math.max(0.42, aspectAt(i)));
      rects.set([column * (cell + gap), bottoms[column], cell, height], i * 4);
      bottoms[column] += height + gap;
    }
    const bottom = count > 0 ? Math.max(...bottoms) - gap : header;
    return new Packed(rects, count, bottom, header, gap);
  }
  function dice(index) {
    let value = (index + 1) * 2654435761;
    value = (value ^ value >>> 15) >>> 0;
    return value % 100;
  }
  function span(aspect, roll, columnCount) {
    if (columnCount < 2) return [1, 1];
    if (roll < 11) return [2, 2];
    if (aspect >= 1.45 && roll < 46) return [2, 1];
    if (aspect <= 0.8 && roll < 46) return [1, 2];
    return [1, 1];
  }
  function mosaic({ count, aspectAt, columns: columnCount, cell, gap, header }) {
    const rects = new Float32Array(count * 4);
    const taken = [];
    const stride = cell + gap;
    const free = (row, col, w, h) => {
      if (col + w > columnCount) return false;
      for (let r = row; r < row + h; r++) {
        for (let c = col; c < col + w; c++) if (taken[r]?.[c]) return false;
      }
      return true;
    };
    let firstOpen = 0;
    let lastRow = -1;
    for (let i = 0; i < count; i++) {
      const [w, h] = span(aspectAt(i), dice(i), columnCount);
      let row = firstOpen;
      let col = 0;
      while (!free(row, col, w, h)) {
        col++;
        if (col >= columnCount) {
          col = 0;
          row++;
        }
      }
      for (let r = row; r < row + h; r++) {
        taken[r] = taken[r] || new Uint8Array(columnCount);
        for (let c = col; c < col + w; c++) taken[r][c] = 1;
      }
      while (taken[firstOpen]?.every(Boolean)) firstOpen++;
      lastRow = Math.max(lastRow, row + h - 1);
      rects.set([col * stride, header + row * stride, w * cell + (w - 1) * gap, h * cell + (h - 1) * gap], i * 4);
    }
    const height = count > 0 ? header + (lastRow + 1) * stride - gap : header;
    return new Packed(rects, count, height, header, gap);
  }
  function whole({ count, aspectAt, columns: columnCount, cell, gap, header }) {
    const rects = new Float32Array(count * 4);
    const pad = cell * 0.06;
    const inner = cell - pad * 2;
    const stride = cell + gap;
    for (let i = 0; i < count; i++) {
      const aspect = aspectAt(i);
      const w = aspect >= 1 ? inner : inner * aspect;
      const h = aspect >= 1 ? inner / aspect : inner;
      const row = Math.floor(i / columnCount);
      const col = i % columnCount;
      rects.set([col * stride + (cell - w) / 2, header + row * stride + (cell - h) / 2, w, h], i * 4);
    }
    const rowCount = Math.ceil(count / columnCount);
    return new Packed(rects, count, count > 0 ? header + rowCount * stride - gap : header, header, gap);
  }
  function feed({ count, aspectAt, width, cell, gap, header }) {
    const rects = new Float32Array(count * 4);
    const column = Math.min(width, Math.max(280, cell * 3.4));
    const space = Math.max(gap, 18);
    let y = header;
    for (let i = 0; i < count; i++) {
      const aspect = Math.max(0.6, aspectAt(i));
      const h = column / aspect;
      rects.set([(width - column) / 2, y, column, h], i * 4);
      y += h + space;
    }
    return new Packed(rects, count, count > 0 ? y - space : header, header, space);
  }
  function prints({ count, columns: columnCount, width, cell, header }) {
    const gap = Math.max(10, cell * 0.11);
    const tile = columnCount > 1 ? (width - (columnCount - 1) * gap) / columnCount : width;
    return new Grid({ count, columns: columnCount, tileW: tile, tileH: tile * 1.18, gapX: gap, gapY: gap, header });
  }
  function film({ count, columns: columnCount, width, cell, gap, header }) {
    const tile = width / columnCount;
    return new Grid({
      count,
      columns: columnCount,
      tileW: tile,
      tileH: Math.max(cell * 0.2, tile * 0.86),
      gapX: 0,
      gapY: Math.max(gap, 10),
      header
    });
  }
  function honeycomb({ count, columns: columnCount, width, gap, header }) {
    const space = Math.max(gap, 4);
    const tile = (width - (columnCount - 0.5) * space) / (columnCount + 0.5);
    return new Grid({
      count,
      columns: columnCount,
      tileW: tile,
      tileH: tile,
      gapX: space,
      gapY: space - tile * 0.13,
      header,
      stagger: (tile + space) / 2
    });
  }
  function details({ count, width, gap, header }) {
    const space = Math.max(gap, 2);
    const columnCount = Math.max(1, Math.floor((width + 16) / 380));
    const tile = (width - (columnCount - 1) * 16) / columnCount;
    return new Grid({ count, columns: columnCount, tileW: tile, tileH: 72, gapX: 16, gapY: space, header });
  }
  var BUILDERS = { grid, rows, columns, mosaic, whole, feed, prints, film, honeycomb, details };
  function buildLayout(style, options) {
    return (BUILDERS[style] || grid)(options);
  }

  // js/timeline_css.js
  var CSS = `
.pkt-tile{position:absolute;padding:0;margin:0;border:0;background:none;cursor:pointer;pointer-events:auto;color:inherit;-webkit-tap-highlight-color:transparent;contain:layout style}
.pkt-tile:focus-visible{outline:2px solid var(--color-primary,#3b82f6);outline-offset:2px;z-index:4}
.pkt-paper{position:absolute;inset:0;display:block;overflow:hidden;background-color:var(--color-base-200,#e5e7eb);transition:inset .42s cubic-bezier(.2,.8,.2,1),border-radius .42s,box-shadow .42s,transform .42s cubic-bezier(.2,.8,.2,1),background-color .42s,padding .42s}
.pkt-paper img{position:absolute;left:var(--pkt-side,0px);top:var(--pkt-top,0px);width:calc(100% - 2*var(--pkt-side,0px));height:calc(100% - var(--pkt-top,0px) - var(--pkt-foot,0px));object-fit:cover;display:block;transition:left .42s,top .42s,width .42s,height .42s,border-radius .42s}
.pkt-badge{position:absolute;right:6px;bottom:6px;display:none;align-items:center;gap:3px;padding:1px 6px 1px 5px;border-radius:999px;background:#000a;color:#fff;font-size:11px;line-height:16px;font-variant-numeric:tabular-nums;pointer-events:none}
.pkt-tile[data-kind="video"] .pkt-badge{display:inline-flex}
.pkt-badge::before{content:"";border-left:7px solid currentColor;border-top:4px solid transparent;border-bottom:4px solid transparent}
.pkt-meta,.pkt-caption{position:absolute;display:block;opacity:0;pointer-events:none;transition:opacity .3s}

[data-active-style="rows"] .pkt-paper{border-radius:3px}
[data-active-style="columns"] .pkt-paper{border-radius:10px}
[data-active-style="mosaic"] .pkt-paper{border-radius:12px}
[data-active-style="whole"] .pkt-paper{border-radius:2px;box-shadow:0 1px 3px #0003}
[data-active-style="feed"] .pkt-paper{border-radius:16px;box-shadow:0 10px 30px -14px #0007}
[data-active-style="honeycomb"] .pkt-paper{border-radius:50%}
[data-active-style="honeycomb"] .pkt-badge{right:50%;transform:translateX(50%)}

[data-active-style="prints"] .pkt-paper{--pkt-side:6%;--pkt-top:5%;--pkt-foot:17%;background-color:#fbfaf5;border-radius:2px;box-shadow:0 1px 2px #0003,0 8px 18px -8px #0006;transform:rotate(var(--pkt-tilt,0deg))}
[data-active-style="prints"] .pkt-caption{opacity:1;left:6%;right:6%;bottom:0;height:17%;display:flex;align-items:center;justify-content:center;color:#57534e;font:italic 500 clamp(9px,1.2vw,13px)/1 ui-serif,Georgia,serif;white-space:nowrap;overflow:hidden}
[data-active-style="prints"] .pkt-badge{bottom:20%;right:9%}
[data-active-style="prints"] .pkt-paper,[data-active-style="prints"] .pkt-paper img{outline:1px solid transparent;will-change:transform}
@media (hover:hover){[data-active-style="prints"] .pkt-tile:hover{z-index:3}[data-active-style="prints"] .pkt-tile:hover .pkt-paper{transform:rotate(0deg) scale(1.05);box-shadow:0 2px 4px #0003,0 16px 28px -10px #0007}}

[data-active-style="film"] .pkt-paper{--pkt-side:3%;--pkt-top:13%;--pkt-foot:13%;background-color:#111113;border-radius:0}
[data-active-style="film"] .pkt-paper::before,[data-active-style="film"] .pkt-paper::after{content:"";position:absolute;left:0;right:0;height:6%;background:repeating-linear-gradient(90deg,transparent 0 6px,#e7e5e4d9 6px 13px,transparent 13px 19px);border-radius:1px}
[data-active-style="film"] .pkt-paper::before{top:3.5%}
[data-active-style="film"] .pkt-paper::after{bottom:3.5%}
[data-active-style="film"] .pkt-paper img{border-radius:3px}
[data-active-style="film"] .pkt-caption{opacity:1;right:6%;bottom:13.5%;color:#fbbf24;font:600 10px/1.2 ui-monospace,Menlo,monospace;text-shadow:0 0 3px #000}
[data-active-style="film"] .pkt-badge{left:6%;right:auto;bottom:15%}

[data-active-style="details"] .pkt-tile{border-radius:12px}
@media (hover:hover){[data-active-style="details"] .pkt-tile:hover{background:color-mix(in oklab,var(--color-base-content,#000) 6%,transparent)}}
[data-active-style="details"] .pkt-paper{inset:6px auto 6px 6px;width:60px;border-radius:9px}
[data-active-style="details"] .pkt-badge{left:9px;right:auto;bottom:9px;padding:0 4px;font-size:9px}
[data-active-style="details"] .pkt-meta{opacity:1;left:78px;right:10px;top:50%;transform:translateY(-50%);text-align:left;line-height:1.3;overflow:hidden;white-space:nowrap}
.pkt-name{display:block;overflow:hidden;text-overflow:ellipsis;font-size:14px;font-weight:600}
.pkt-sub{display:block;overflow:hidden;text-overflow:ellipsis;font-size:12px;opacity:.62;font-variant-numeric:tabular-nums}

.pkt-check{position:absolute;left:6px;top:6px;width:22px;height:22px;border-radius:50%;border:2px solid #fffd;background:#0003;box-shadow:0 0 0 1px #0002;opacity:0;transform:scale(.8);transition:opacity .14s,transform .14s,background-color .14s;display:none}
[data-selectable="true"] .pkt-check{display:block}
.pkt-check::after{content:"";position:absolute;left:5.5px;top:2px;width:6px;height:10px;border:solid #fff;border-width:0 2px 2px 0;transform:rotate(42deg);opacity:0}
@media (hover:hover){.pkt-tile:hover .pkt-check{opacity:1;transform:scale(1)}}
[data-selecting="true"] .pkt-check{opacity:1;transform:scale(1)}
.pkt-tile[data-selected] .pkt-check{background:var(--color-primary,#2563eb);border-color:var(--color-primary,#2563eb);opacity:1;transform:scale(1)}
.pkt-tile[data-selected] .pkt-check::after{opacity:1}
.pkt-tile[data-selected] .pkt-paper{transform:scale(.9);border-radius:10px;box-shadow:0 0 0 2px var(--color-primary,#2563eb)}
[data-active-style="prints"] .pkt-tile[data-selected] .pkt-paper{transform:rotate(var(--pkt-tilt,0deg)) scale(.93)}
[data-active-style="honeycomb"] .pkt-tile[data-selected] .pkt-paper{border-radius:50%}
[data-active-style="details"] .pkt-tile[data-selected]{background:color-mix(in oklab,var(--color-primary,#2563eb) 12%,transparent)}
[data-active-style="details"] .pkt-tile[data-selected] .pkt-paper{transform:none;box-shadow:none;border-radius:9px}
[data-active-style="details"] .pkt-check{left:auto;right:12px;top:50%;margin-top:-11px;border-color:color-mix(in oklab,var(--color-base-content,#000) 45%,transparent);background:transparent}
[data-active-style="honeycomb"] .pkt-check{left:14%;top:14%}
[data-dragging="true"]{user-select:none;-webkit-user-select:none;cursor:crosshair}
[data-selectable="true"] .pkt-tile{-webkit-touch-callout:none;-webkit-user-select:none;user-select:none}
.pkt-marquee{position:absolute;z-index:6;border:1px solid var(--color-primary,#2563eb);background:color-mix(in oklab,var(--color-primary,#2563eb) 16%,transparent);border-radius:3px;pointer-events:none}

.pkt-header{display:flex;align-items:center;gap:8px}
.pkt-section-check{pointer-events:auto;position:relative;width:20px;height:20px;padding:0;border-radius:50%;border:2px solid color-mix(in oklab,var(--color-base-content,#000) 40%,transparent);background:none;cursor:pointer;opacity:0;transition:opacity .14s}
.pkt-section-check::after{content:"";position:absolute;left:4.5px;top:1.5px;width:6px;height:10px;border:solid color-mix(in oklab,var(--color-base-content,#000) 55%,transparent);border-width:0 2px 2px 0;transform:rotate(42deg)}
@media (hover:hover){.pkt-header:hover .pkt-section-check,.pkt-section-check:focus-visible{opacity:1}}
[data-selecting="true"] .pkt-section-check{opacity:1}
@media (prefers-reduced-motion:reduce){.pkt-paper,.pkt-paper img,.pkt-meta,.pkt-caption,.pkt-check{transition:none}}
`;
  var installed = false;
  function installTimelineCss() {
    if (installed || typeof document === "undefined") return;
    installed = true;
    try {
      const sheet = new CSSStyleSheet();
      sheet.replaceSync(CSS);
      document.adoptedStyleSheets = [...document.adoptedStyleSheets, sheet];
    } catch (_error) {
      const style = document.createElement("style");
      style.textContent = CSS;
      document.head.appendChild(style);
    }
  }

  // js/tiles.js
  var SHARP_ENOUGH = 0.75;
  function tilt(id) {
    let hash = 0;
    for (let i = 0; i < id.length; i++) hash = hash * 31 + id.charCodeAt(i) | 0;
    return ((hash >>> 0) % 500 / 100 - 2.5).toFixed(2);
  }
  function span2(className, text) {
    const node = document.createElement("span");
    node.className = className;
    if (text) node.textContent = text;
    return node;
  }
  function formatDate(iso, options) {
    if (!iso) return "";
    const date = new Date(iso);
    if (Number.isNaN(date.getTime())) return "";
    try {
      return new Intl.DateTimeFormat(document.documentElement.lang || void 0, options).format(date);
    } catch (_error) {
      return date.toDateString();
    }
  }
  function formatBytes(bytes) {
    if (!Number.isFinite(bytes) || bytes <= 0) return "";
    const units = ["B", "KB", "MB", "GB"];
    const power = Math.min(units.length - 1, Math.floor(Math.log(bytes) / Math.log(1024)));
    const value = bytes / 1024 ** power;
    return `${value >= 10 || power === 0 ? Math.round(value) : value.toFixed(1)} ${units[power]}`;
  }
  function formatDuration(seconds) {
    if (!Number.isFinite(seconds) || seconds <= 0) return "";
    const whole2 = Math.round(seconds);
    return `${Math.floor(whole2 / 60)}:${String(whole2 % 60).padStart(2, "0")}`;
  }
  function fillTile(node, item) {
    node.dataset.kind = item.kind || "image";
    node.style.setProperty("--pkt-tilt", `${tilt(item.id)}deg`);
    const paper = span2("pkt-paper");
    const img = document.createElement("img");
    img.alt = "";
    img.loading = "lazy";
    img.decoding = "async";
    img.draggable = false;
    paper.appendChild(img);
    const date = formatDate(item.taken_at, { day: "numeric", month: "short", year: "numeric" });
    const caption = span2("pkt-caption", date);
    const facts = [
      formatDate(item.taken_at, { dateStyle: "medium", timeStyle: "short" }),
      formatBytes(item.size),
      item.w && item.h ? `${item.w} \xD7 ${item.h}` : ""
    ];
    const meta = span2("pkt-meta");
    meta.append(span2("pkt-name", item.name || date), span2("pkt-sub", facts.filter(Boolean).join(" \xB7 ")));
    node.append(paper, caption, meta, span2("pkt-badge", formatDuration(item.duration)), span2("pkt-check"));
  }
  function pickSource(item, w, h, style, density = 1) {
    const need = Math.max(w, h) * density * SHARP_ENOUGH;
    const square = Math.abs(w - h) < 2 || style.crop && Math.max(w, h) / Math.min(w, h) < 1.25;
    if (square && need <= 340 && item.thumb) return item.thumb;
    if (need <= 300 && item.fit) return item.fit;
    if (need <= 820 && item.preview) return item.preview;
    return item.large || item.preview || item.fit || item.thumb;
  }
  function swapImage(node, img, src) {
    if (img.dataset.next === src) return;
    img.dataset.next = src;
    const next = img.cloneNode();
    next.src = src;
    next.dataset.src = src;
    delete next.dataset.next;
    next.loading = "eager";
    next.style.opacity = "0";
    const show = () => {
      if (img.dataset.next !== src || !img.isConnected) {
        next.remove();
        return;
      }
      next.style.opacity = "";
      if (next.animate) {
        next.animate([{ opacity: 0 }, { opacity: 1 }], { duration: 220 }).finished.then(() => img.remove(), () => img.remove());
      } else {
        img.remove();
      }
    };
    img.parentNode.appendChild(next);
    next.decode ? next.decode().then(show, () => next.remove()) : next.onload = show;
  }

  // js/morph.js
  var DURATION = 460;
  var WAVE = 200;
  var EASING = "cubic-bezier(.2,.85,.2,1)";
  var LAYOUT_LIMIT = 260;
  function reducedMotion() {
    return typeof window !== "undefined" && window.matchMedia ? window.matchMedia("(prefers-reduced-motion: reduce)").matches : false;
  }
  function px(rect) {
    return { left: `${rect.x}px`, top: `${rect.y}px`, width: `${rect.w}px`, height: `${rect.h}px` };
  }
  function moved(a, b) {
    return Math.abs(a.x - b.x) > 0.5 || Math.abs(a.y - b.y) > 0.5 || Math.abs(a.w - b.w) > 0.5 || Math.abs(a.h - b.h) > 0.5;
  }
  function onScreen(rect, shift, { top, height }) {
    const y = rect.y + shift;
    const reach = height * 0.6;
    return { ...rect, y: Math.min(top + height + reach, Math.max(top - reach - rect.h, y)) };
  }
  function delayFor(rect, focusX, focusY, reach) {
    const distance2 = Math.hypot(rect.x + rect.w / 2 - focusX, rect.y + rect.h / 2 - focusY);
    return Math.min(1, distance2 / reach) * WAVE;
  }
  function travel(node, from, to, delay, options, heavy) {
    const fade = options.fade ? [options.fade[0], options.fade[1]] : [1, 1];
    const keyframes = heavy ? [
      {
        transform: `translate(${from.x - to.x}px, ${from.y - to.y}px) scale(${from.w / to.w || 1}, ${from.h / to.h || 1})`,
        transformOrigin: "0 0",
        opacity: fade[0]
      },
      { transform: "none", transformOrigin: "0 0", opacity: fade[1] }
    ] : [{ ...px(from), opacity: fade[0] }, { ...px(to), opacity: fade[1] }];
    return node.animate(keyframes, { duration: DURATION, delay, easing: EASING, fill: "both" });
  }
  function morph({ tiles, from, leaving, shift, viewport, focusX, focusY, previousRect, nextRect }) {
    const clear = (node) => node.remove();
    if (reducedMotion() || typeof Element === "undefined" || !Element.prototype.animate) {
      leaving.forEach(clear);
      return;
    }
    const reach = Math.max(1, viewport.height * 0.9);
    const nodes = [...tiles].filter(([key]) => !key.startsWith("header:"));
    const heavy = nodes.length + leaving.size > LAYOUT_LIMIT;
    for (const [key, node] of nodes) {
      const to = {
        x: parseFloat(node.style.left),
        y: parseFloat(node.style.top),
        w: parseFloat(node.style.width),
        h: parseFloat(node.style.height)
      };
      const known = from.get(key) || previousRect(Number(node.dataset.global));
      if (!known) {
        travel(node, { ...to, y: to.y + 24 }, to, delayFor(to, focusX, focusY, reach), { fade: [0, 1] }, heavy);
        continue;
      }
      const start = onScreen(known, shift, viewport);
      if (moved(start, to)) travel(node, start, to, delayFor(to, focusX, focusY, reach), {}, heavy);
    }
    for (const [key, node] of leaving) {
      const start = onScreen(from.get(key) || { x: 0, y: 0, w: 1, h: 1 }, shift, viewport);
      const target = nextRect(Number(node.dataset.global));
      node.style.left = `${start.x}px`;
      node.style.top = `${start.y}px`;
      node.style.width = `${start.w}px`;
      node.style.height = `${start.h}px`;
      const to = target ? onScreen(target, 0, viewport) : start;
      travel(node, start, to, delayFor(start, focusX, focusY, reach), { fade: [1, 0] }, false).finished.then(() => clear(node), () => clear(node));
    }
  }

  // js/selection.js
  var HOLD_MS = 380;
  var DRAG_PX = 6;
  var HOLD_SLOP_PX = 10;
  var EDGE_PX = 64;
  var EDGE_SPEED = 18;
  var MOMENT_GAP_MS = 4 * 60 * 1e3;
  var selection = {
    selected: null,
    selectAnchor: null,
    selectMode: false,
    selectable() {
      return this.el.dataset.selectable === "true";
    },
    /** Whether a plain click toggles instead of opening. */
    selecting() {
      return this.selectMode || (this.selected?.size || 0) > 0;
    },
    isSelected(id) {
      return Boolean(this.selected?.has(id));
    },
    /** The number and the id of what is chosen, for a request. */
    selectedIds() {
      return [...this.selected || []];
    },
    // --- changing what is chosen ---------------------------------------------
    toggleSelected(id, global) {
      this.selected = this.selected || /* @__PURE__ */ new Set();
      if (this.selected.has(id)) this.selected.delete(id);
      else this.selected.add(id);
      this.selectAnchor = global;
      this.selectionChanged();
    },
    clearSelection() {
      this.selected?.clear();
      this.selectMode = false;
      this.selectAnchor = null;
      this.selectionChanged();
    },
    addSelected(ids) {
      this.selected = this.selected || /* @__PURE__ */ new Set();
      for (const id of ids) this.selected.add(id);
      this.selectionChanged();
    },
    removeSelected(ids) {
      for (const id of ids) this.selected?.delete(id);
      this.selectionChanged();
    },
    /** The ids of positions `from` to `to`, or null when some have not been fetched. */
    loadedIds(from, to) {
      const ids = [];
      for (let global = from; global <= to; global++) {
        const id = this.itemAtGlobal(global)?.id;
        if (!id) return null;
        ids.push(id);
      }
      return ids;
    },
    itemAtGlobal(global) {
      const found = this.sectionOf(global);
      if (found < 0) return null;
      let cursor = global - this.sectionStarts[found];
      for (const day of this.sections[found].days_list || []) {
        const count = day.count || 0;
        if (cursor < count) return this.windows.get(day.id)?.[cursor] || null;
        cursor -= count;
      }
      return null;
    },
    sectionOf(global) {
      let found = -1;
      const starts = this.sectionStarts || [];
      for (let i = 0; i < starts.length && starts[i] <= global; i++) found = i;
      return found;
    },
    /**
     * Take a run of positions. What is on hand is taken at once; the rest comes from the server.
     * `mode` is add, remove, or toggle: remove when the whole run is already chosen.
     */
    selectRange(from, to, mode = "add") {
      const [first, last] = from <= to ? [from, to] : [to, from];
      const ids = this.loadedIds(first, last);
      if (ids) this.applyRange({ ids, mode });
      else this.send("timeline:range", { from: first, to: last, mode, revision: this.revision });
    },
    applyRange({ ids, mode, capped, revision }) {
      if (revision !== void 0 && revision !== this.revision) return;
      const remove = mode === "remove" || mode === "toggle" && ids.every((id) => this.selected?.has(id));
      if (remove) this.removeSelected(ids);
      else this.addSelected(ids);
      this.noteCapped(capped);
    },
    /** The server took as many as a selection may hold; say so where the count is. */
    noteCapped(capped) {
      const note = this.root()?.querySelector("[data-selection-capped]");
      if (note) note.hidden = !capped;
    },
    /** Everything between the last tile touched and this one. */
    selectTo(global) {
      this.selectRange(this.selectAnchor, global);
      this.selectAnchor = global;
    },
    /** The whole of a month. */
    selectSection(index) {
      const section = this.sections[index];
      if (!section || section.count <= 0) return;
      const first = this.sectionStarts[index];
      this.selectRange(first, first + section.count - 1, "toggle");
    },
    selectAll() {
      const total = (this.sections || []).reduce((sum, section) => sum + section.count, 0);
      if (total > 0) this.selectRange(0, total - 1);
    },
    /** The day of the last tile touched. */
    selectDay() {
      const global = this.selectAnchor;
      const found = global === null ? -1 : this.sectionOf(global);
      if (found < 0) return;
      let start = this.sectionStarts[found];
      const days = this.sections[found].days_list || [];
      for (let i = 0; i < days.length; i++) {
        const day = days[i].id.split(":")[0];
        let end = start;
        let j = i;
        for (; j < days.length && days[j].id.split(":")[0] === day; j++) end += days[j].count || 0;
        if (global < end) {
          this.selectRange(start, end - 1);
          return;
        }
        start = end;
        i = j - 1;
      }
    },
    /** The photos taken around the last tile touched: a burst, a walk down one street. */
    selectMoment() {
      const global = this.selectAnchor;
      if (global === null) return;
      const time = (at) => {
        const stamp = this.itemAtGlobal(at)?.taken_at;
        return stamp ? Date.parse(stamp) : NaN;
      };
      let first = global;
      let last = global;
      while (first > 0 && time(first) - time(first - 1) <= MOMENT_GAP_MS) first--;
      while (time(last + 1) - time(last) <= MOMENT_GAP_MS) last++;
      this.selectRange(first, last);
    },
    /** Ask the server for one kind of file in the whole library: `video` or `image`. */
    selectKind(kind) {
      this.send("timeline:range", { kind, mode: "add", revision: this.revision });
    },
    // --- showing it -----------------------------------------------------------
    root() {
      return this.el.closest?.(".phoenix-kit-photo-timeline") || null;
    },
    selectionChanged() {
      const count = this.selected?.size || 0;
      if (this.el.dataset) this.el.dataset.selecting = this.selecting() ? "true" : "false";
      for (const [key, node] of this.pool) {
        if (!key.startsWith("header:")) node.toggleAttribute?.("data-selected", this.isSelected(key));
      }
      const root = this.root();
      if (!root) return;
      const bar = root.querySelector("[data-selection-bar]");
      if (bar) bar.hidden = !this.selecting();
      const counter = root.querySelector("[data-selection-count]");
      if (counter) counter.textContent = count.toLocaleString(document.documentElement.lang || void 0);
      if (count === 0) this.noteCapped(false);
      for (const button of root.querySelectorAll("[data-bulk]")) button.disabled = count === 0;
    },
    /** A tile was clicked. */
    tileClick(event, node, id) {
      if (Date.now() - (this.dragEndedAt || 0) < 60) return;
      const global = Number(node.dataset.global);
      if (!this.selectable()) return this.openTile(id, global);
      if (event.shiftKey && this.selectAnchor !== null) {
        this.selectTo(global);
      } else if (event.target.closest?.(".pkt-check") || event.metaKey || event.ctrlKey || this.selecting()) {
        this.toggleSelected(id, global);
      } else {
        this.openTile(id, global);
      }
    },
    // --- mouse: drawing a box ---------------------------------------------------
    /** The pointer on the page, on the layer: the box lives there, and so scrolls with the tiles. */
    layerPoint(event) {
      const box = this.el.getBoundingClientRect();
      return { x: event.clientX - box.left, y: event.clientY - box.top + this.el.scrollTop, clientY: event.clientY };
    },
    pointerDown(event) {
      if (!this.selectable() || this.pager || event.button !== 0) return;
      const tile = event.target.closest?.(".pkt-tile");
      if (event.pointerType === "mouse") {
        const box = this.el.getBoundingClientRect();
        if (event.clientX >= box.left + this.el.clientWidth) return;
        if (event.target.closest?.("[data-section-select]")) return;
        this.drag = { start: this.layerPoint(event), keep: event.shiftKey || event.metaKey || event.ctrlKey || this.selecting() };
        window.addEventListener("pointermove", this.onDragMove);
        window.addEventListener("pointerup", this.onDragEnd);
        window.addEventListener("pointercancel", this.onDragEnd);
      } else if (tile) {
        clearTimeout(this.holdTimer);
        this.hold = { x: event.clientX, y: event.clientY };
        this.holdTimer = setTimeout(() => this.beginPaint(tile), HOLD_MS);
      }
    },
    dragMove(event) {
      const drag = this.drag;
      if (!drag) return;
      drag.last = this.layerPoint(event);
      if (!drag.box) {
        if (Math.hypot(drag.last.x - drag.start.x, drag.last.y - drag.start.y) < DRAG_PX) return;
        drag.base = new Set(drag.keep ? this.selected || [] : []);
        drag.box = document.createElement("div");
        drag.box.className = "pkt-marquee";
        this.layer.appendChild(drag.box);
        this.el.dataset.dragging = "true";
      }
      this.drawBox();
      this.edgeScroll(event.clientY);
    },
    /** Draw the box, and choose what it touches. Runs again when windows arrive under it. */
    drawBox() {
      const drag = this.drag;
      if (!drag?.box) return;
      const left = Math.min(drag.start.x, drag.last.x);
      const top = Math.min(drag.start.y, drag.last.y);
      const right = Math.max(drag.start.x, drag.last.x);
      const bottom = Math.max(drag.start.y, drag.last.y);
      Object.assign(drag.box.style, {
        left: `${left}px`,
        top: `${top}px`,
        width: `${right - left}px`,
        height: `${bottom - top}px`
      });
      this.selected = new Set(drag.base);
      for (const id of this.idsInBox(left, top, right, bottom)) this.selected.add(id);
      this.selectionChanged();
    },
    idsInBox(left, top, right, bottom) {
      const ids = [];
      for (let index = 0; index < this.sections.length; index++) {
        const start = this.offsets[index];
        if (this.offsets[index + 1] < top) continue;
        if (start > bottom) break;
        const section = this.sections[index];
        const layout = this.layoutOf(section);
        const { first, last } = layout.range(top - start, bottom - start);
        for (let item = first; item <= last; item++) {
          const r = layout.rect(item);
          const y = start + r.y;
          if (r.x > right || r.x + r.w < left || y > bottom || y + r.h < top) continue;
          const found = this.itemAtGlobal(this.sectionStarts[index] + item);
          if (found) ids.push(found.id);
        }
      }
      return ids;
    },
    /** Near the top or bottom of the page the box, or the finger, takes the page along. */
    edgeScroll(clientY) {
      const box = this.el.getBoundingClientRect();
      const top = box.top + this.inset;
      const speed = clientY < top + EDGE_PX ? -EDGE_SPEED * Math.min(1, (top + EDGE_PX - clientY) / EDGE_PX) : clientY > box.bottom - EDGE_PX ? EDGE_SPEED * Math.min(1, (clientY - box.bottom + EDGE_PX) / EDGE_PX) : 0;
      this.edgeSpeed = speed;
      if (speed && !this.edgeFrame) this.edgeFrame = requestAnimationFrame(() => this.edgeStep());
    },
    edgeStep() {
      this.edgeFrame = null;
      if (!this.edgeSpeed || !(this.drag?.box || this.paint)) return;
      this.el.scrollTop += this.edgeSpeed;
      if (this.drag?.last) {
        this.drag.last = { ...this.drag.last, y: this.drag.last.y + this.edgeSpeed };
        this.drawBox();
      }
      this.edgeFrame = requestAnimationFrame(() => this.edgeStep());
    },
    dragEnd() {
      const drag = this.drag;
      this.drag = null;
      this.edgeSpeed = 0;
      window.removeEventListener("pointermove", this.onDragMove);
      window.removeEventListener("pointerup", this.onDragEnd);
      window.removeEventListener("pointercancel", this.onDragEnd);
      if (!drag?.box) return;
      drag.box.remove();
      delete this.el.dataset.dragging;
      this.dragEndedAt = Date.now();
    },
    // --- touch: hold, then slide ---------------------------------------------------
    beginPaint(tile) {
      this.hold = null;
      const global = Number(tile.dataset.global);
      const id = tile.dataset.fileId;
      this.selected = this.selected || /* @__PURE__ */ new Set();
      const removing = this.selected.has(id);
      this.paint = { from: global, to: global, base: new Set(this.selected), removing };
      this.selectAnchor = global;
      this.paintTo(global);
      navigator.vibrate?.(12);
    },
    paintTo(global) {
      const paint = this.paint;
      paint.to = global;
      const [from, to] = paint.from <= global ? [paint.from, global] : [global, paint.from];
      this.selected = new Set(paint.base);
      for (let at = from; at <= to; at++) {
        const id = this.itemAtGlobal(at)?.id;
        if (!id) continue;
        if (paint.removing) this.selected.delete(id);
        else this.selected.add(id);
      }
      this.selectionChanged();
    },
    /** Claims the touch for the selection: the page must not scroll while a finger paints. */
    selectionTouchMove(event) {
      if (this.hold) {
        const touch2 = event.touches[0];
        if (touch2 && Math.hypot(touch2.clientX - this.hold.x, touch2.clientY - this.hold.y) > HOLD_SLOP_PX) this.cancelHold();
      }
      if (!this.paint) return;
      event.preventDefault();
      const touch = event.touches[0];
      if (!touch) return;
      const tile = document.elementFromPoint(touch.clientX, touch.clientY)?.closest?.(".pkt-tile");
      if (tile) this.paintTo(Number(tile.dataset.global));
      this.edgeScroll(touch.clientY);
    },
    cancelHold() {
      clearTimeout(this.holdTimer);
      this.hold = null;
    },
    selectionTouchEnd() {
      this.cancelHold();
      if (!this.paint) return;
      this.paint = null;
      this.edgeSpeed = 0;
      this.dragEndedAt = Date.now();
    },
    // --- keys, the bar, the headers -----------------------------------------------
    selectionKey(event) {
      if (!this.selectable() || this.pager) return;
      const target = event.target;
      if (target && (/^(input|select|textarea)$/i.test(target.tagName || "") || target.isContentEditable)) return;
      if (event.key === "Escape" && this.selecting()) {
        this.clearSelection();
      } else if ((event.metaKey || event.ctrlKey) && event.key.toLowerCase() === "a") {
        event.preventDefault();
        this.selectAll();
      } else if ((event.key === "Delete" || event.key === "Backspace") && (this.selected?.size || 0) > 0) {
        event.preventDefault();
        this.bulk("trash");
      }
    },
    /** Ask for an action on what is chosen. The server checks each file and answers with a plan. */
    bulk(action) {
      const ids = this.selectedIds();
      if (ids.length === 0) return;
      if (action === "download") this.download(ids);
      else this.send("timeline:bulk", { action, ids });
    },
    /**
     * A form posted to the host's download address: the answer is an attachment, so the page stays,
     * and thousands of ids fit in a body where they would not fit in a link.
     */
    download(ids) {
      const root = this.root();
      const action = root?.dataset.downloadPath;
      if (!action) return;
      const form = document.createElement("form");
      form.method = "post";
      form.action = action;
      form.hidden = true;
      const field = (name, value) => {
        const input = document.createElement("input");
        input.type = "hidden";
        input.name = name;
        input.value = value;
        form.appendChild(input);
      };
      field("_csrf_token", document.querySelector("meta[name='csrf-token']")?.content || "");
      field("ids", ids.join(","));
      document.body.appendChild(form);
      form.submit();
      form.remove();
    },
    /** The addresses of what is chosen, as a person will paste them: with the site in front. */
    showLinks({ paths }) {
      const box = this.root()?.querySelector("[data-links]");
      if (box) box.value = (paths || []).map((path) => window.location.origin + path).join("\n");
    },
    /** Every click on the bar, and on a month's circle. */
    selectionClick(event) {
      const target = event.target;
      const action = target.closest?.("[data-bulk]");
      if (action) return this.bulk(action.dataset.bulk);
      const copy = target.closest?.("[data-copy-links]");
      if (copy) {
        const box = this.root()?.querySelector("[data-links]");
        if (!box) return;
        box.select();
        navigator.clipboard?.writeText(box.value);
        copy.textContent = copy.dataset.done || copy.textContent;
        return;
      }
      const pick = target.closest?.("[data-select]");
      if (pick) {
        const choices = {
          all: () => this.selectAll(),
          day: () => this.selectDay(),
          moment: () => this.selectMoment(),
          videos: () => this.selectKind("video"),
          photos: () => this.selectKind("image"),
          none: () => this.clearSelection()
        };
        choices[pick.dataset.select]?.();
        target.closest?.("details")?.removeAttribute("open");
        return;
      }
      if (target.closest?.("[data-select-start]")) {
        this.selectMode = !this.selecting();
        if (!this.selectMode) this.clearSelection();
        else this.selectionChanged();
      }
    },
    /** The server finished, or changed what may stay chosen. */
    applySelection({ clear, remove }) {
      if (clear) this.clearSelection();
      else if (remove) this.removeSelected(remove);
    },
    bindSelection() {
      if (!this.selectable()) return;
      this.selected = this.selected || /* @__PURE__ */ new Set();
      this.onDragMove = (event) => this.dragMove(event);
      this.onDragEnd = () => this.dragEnd();
      this.onSelectDown = (event) => this.pointerDown(event);
      this.onSelectKey = (event) => this.selectionKey(event);
      this.onSelectClick = (event) => this.selectionClick(event);
      this.onSelectTouchMove = (event) => this.selectionTouchMove(event);
      this.onSelectTouchEnd = () => this.selectionTouchEnd();
      this.onSelectContext = (event) => {
        if (this.paint || this.hold) event.preventDefault();
      };
      this.el.addEventListener("pointerdown", this.onSelectDown);
      this.el.addEventListener("touchmove", this.onSelectTouchMove, { passive: false });
      this.el.addEventListener("touchend", this.onSelectTouchEnd);
      this.el.addEventListener("touchcancel", this.onSelectTouchEnd);
      this.el.addEventListener("contextmenu", this.onSelectContext);
      window.addEventListener("keydown", this.onSelectKey);
      this.root()?.addEventListener("click", this.onSelectClick);
      this.selectionChanged();
    },
    unbindSelection() {
      if (!this.onSelectDown) return;
      this.dragEnd();
      this.cancelHold();
      this.el.removeEventListener("pointerdown", this.onSelectDown);
      this.el.removeEventListener("touchmove", this.onSelectTouchMove);
      this.el.removeEventListener("touchend", this.onSelectTouchEnd);
      this.el.removeEventListener("touchcancel", this.onSelectTouchEnd);
      this.el.removeEventListener("contextmenu", this.onSelectContext);
      window.removeEventListener("keydown", this.onSelectKey);
      this.root()?.removeEventListener("click", this.onSelectClick);
    }
  };

  // js/photo_timeline.js
  init_slides();
  init_engine();

  // js/viewer/engines.js
  init_engine();
  registerEngine("photoswipe", () => Promise.resolve().then(() => (init_photoswipe2(), photoswipe_exports)).then((m) => m.PhotoSwipeEngine));
  registerEngine("snap", () => Promise.resolve().then(() => (init_snap(), snap_exports)).then((m) => m.SnapEngine));

  // js/photo_timeline.js
  init_video();
  var DEFAULTS = { cell: 160, gap: 4, header: 40 };
  var STALE_AFTER_MS = 60 * 60 * 1e3;
  var RELOAD_EVERY_MS = 10 * 1e3;
  var ECHO_MS = 5 * 1e3;
  var MIN_CELL = 56;
  var ZOOM_KEY = "phoenix_kit_photos:cell";
  var STYLE_KEY = "phoenix_kit_photos:style";
  var ASPECTS_WAIT_MS = 1500;
  var PhotoTimeline = {
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
      this.el.style.overflowAnchor = "none";
      this.columns = Math.max(1, parseInt(this.el.dataset.columns || "5", 10) || 5);
      this.baseColumns = this.columns;
      this.targetCell = parseInt(this.el.dataset.cell || "0", 10) || 0;
      this.fill = this.el.dataset.fill === "true";
      this.metrics = { ...DEFAULTS };
      const gap = parseInt(this.el.dataset.gap || "", 10);
      if (Number.isFinite(gap) && gap >= 0) this.metrics.gap = gap;
      this.inset = 0;
      this.zoomCell = this.storedZoom();
      this.pinch = null;
      this.current = this.el.closest(".phoenix-kit-photo-timeline")?.querySelector("[data-current-section]");
      this.sections = [];
      this.offsets = [0];
      this.windows = /* @__PURE__ */ new Map();
      this.fetchedAt = /* @__PURE__ */ new Map();
      this.lastReload = 0;
      this.known = /* @__PURE__ */ new Set();
      this.fresh = /* @__PURE__ */ new Set();
      this.refreshing = /* @__PURE__ */ new Set();
      this.pool = /* @__PURE__ */ new Map();
      this.library = null;
      this.revision = null;
      this.needed = /* @__PURE__ */ new Set();
      this.aspects = /* @__PURE__ */ new Map();
      this.slides = new SlideStore([]);
      this.sectionStarts = [];
      this.pager = null;
      this.pendingOpen = null;
      this.frozenAnchor = null;
      this.spacer = this.el.querySelector(".phoenix-kit-photo-timeline__spacer");
      this.layer = this.el.querySelector(".phoenix-kit-photo-timeline__layer");
      installTimelineCss();
      this.styleId = this.startingStyle();
      this.el.dataset.activeStyle = this.styleId;
      this.bindStyleMenu();
      this.bindSelection();
      this.mountBookmark();
      this.onPositionInput = (event) => this.beginPositionInput(event);
      this.positionInputs = ["wheel", "touchmove", "pointerdown", "keydown"];
      for (const event of this.positionInputs) this.el.addEventListener(event, this.onPositionInput, { passive: true });
      this.onScroll = throttleToFrame(() => this.handleScroll());
      this.el.addEventListener("scroll", this.onScroll, { passive: true });
      this.bindZoom();
      this.onImageError = () => this.imageFailed();
      this.layer.addEventListener("error", this.onImageError, true);
      this.onPageHide = () => this.freezePosition();
      window.addEventListener("pagehide", this.onPageHide);
      this.onWake = () => {
        if (document.visibilityState === "hidden") this.freezePosition();
        if (document.visibilityState === "visible") {
          this.handleScroll();
          this.reloadWindows({ olderThan: STALE_AFTER_MS });
        }
      };
      document.addEventListener("visibilitychange", this.onWake);
      window.addEventListener("pageshow", this.onWake);
      this.onWindowBlur = () => this.freezePosition();
      this.onWindowFocus = () => {
        this.freezePosition();
        this.handleScroll();
      };
      window.addEventListener("blur", this.onWindowBlur);
      window.addEventListener("focus", this.onWindowFocus);
      this.onResize = debounce(() => this.handleResize(), 120);
      window.addEventListener("resize", this.onResize);
      this.resizeObserver = new ResizeObserver(this.onResize);
      this.resizeObserver.observe(this.el);
      const prefix = `timeline:${this.el.dataset.timelineId}`;
      this.handleEvent(`${prefix}:index`, (payload) => this.setIndex(payload));
      this.handleEvent(`${prefix}:window`, (payload) => this.setWindow(payload));
      this.handleEvent(`${prefix}:jump`, ({ id }) => this.jumpTo(id));
      this.handleEvent(`${prefix}:view`, (payload) => this.applyView(payload));
      this.handleEvent(`${prefix}:slides`, (payload) => this.setSlides(payload));
      this.handleEvent(`${prefix}:aspects`, (payload) => this.setAspects(payload));
      this.handleEvent(`${prefix}:range`, (payload) => this.applyRange(payload));
      this.handleEvent(`${prefix}:selection`, (payload) => this.applySelection(payload));
      this.handleEvent(`${prefix}:links`, (payload) => this.showLinks(payload));
      this.send("timeline:ready", this.readyPayload());
    },
    send(event, payload) {
      this.pushEventTo(Number(this.el.dataset.target), event, payload);
    },
    disconnected() {
      this.freezePosition();
    },
    reconnected() {
      this.handleScroll();
      this.send("timeline:ready", this.readyPayload());
      this.reloadWindows({ olderThan: STALE_AFTER_MS });
    },
    destroyed() {
      for (const event of this.positionInputs) this.el.removeEventListener(event, this.onPositionInput);
      this.bookmarkMark?.remove();
      window.removeEventListener("pagehide", this.onPageHide);
      this.unbindZoom();
      this.el.removeEventListener("scroll", this.onScroll);
      this.layer.removeEventListener("error", this.onImageError, true);
      document.removeEventListener("visibilitychange", this.onWake);
      window.removeEventListener("pageshow", this.onWake);
      window.removeEventListener("blur", this.onWindowBlur);
      window.removeEventListener("focus", this.onWindowFocus);
      clearTimeout(this.positionInputTimer);
      window.removeEventListener("resize", this.onResize);
      this.unbindStyleMenu();
      this.unbindSelection();
      clearTimeout(this.aspectsTimer);
      this.resizeObserver.disconnect();
      this.onResize.cancel();
      this.onScroll.cancel();
      clearTimeout(this.openTimer);
      this.addressClosing = true;
      if (this.pager && this.pager.destroy) this.pager.destroy();
      this.pool.clear();
    },
    setIndex(payload) {
      const libraryChanged = payload.library !== this.library;
      if (!libraryChanged && this.pager) {
        this.deferred = payload;
        return;
      }
      const refresh = !libraryChanged && this.revision !== null;
      const anchor = libraryChanged ? null : this.positionInput ? this.captureAnchor() : this.bookmarkAnchor || this.captureAnchor();
      const atEnd = refresh && this.atEnd() && (!this.bookmarkAnchor || Math.abs((this.offsets[this.bookmarkAnchor.index] || 0) + this.bookmarkAnchor.delta - this.inset - this.el.scrollTop) < 2);
      const heightBefore = totalHeight(this.offsets);
      if (libraryChanged) this.rememberPosition();
      this.library = payload.library;
      if (payload.revision === this.revision && !libraryChanged) return;
      this.revision = payload.revision;
      if (libraryChanged) {
        this.windows.clear();
        this.known.clear();
        this.aspects?.clear();
        this.selected?.clear();
        this.selectMode = false;
        this.selectAnchor = null;
      }
      this.fresh.clear();
      this.refreshing.clear();
      this.sections = payload.sections || [];
      this.storeAspects(payload.aspects);
      this.resetSlides();
      if (payload.metrics) {
        const { gap, ...rest } = payload.metrics;
        this.metrics = { ...this.metrics, ...rest };
        if (this.el.dataset.gap === void 0 && gap !== void 0) this.metrics.gap = gap;
      }
      const saved = libraryChanged ? this.storedPosition() : null;
      this.recordPosition("index", { libraryChanged, saved: Boolean(saved) });
      if (libraryChanged) this.frozenAnchor = saved?.anchor || null;
      this.relayout(this.frozenAnchor || saved?.anchor || anchor);
      if (libraryChanged && !saved) {
        const height = totalHeight(this.offsets);
        this.el.scrollTop = Math.max(0, height - this.el.clientHeight);
      } else if (!this.frozenAnchor && atEnd && totalHeight(this.offsets) > heightBefore) {
        this.followEnd();
      }
      if (libraryChanged) {
        this.bookmarkAnchor = saved?.anchor || this.captureAnchor();
        if (!saved) this.rememberPosition();
      }
      this.markStyle(this.styleId);
      if (refresh) this.revalidate();
      this.markNew = refresh;
      this.handleScroll();
      this.markNew = false;
      this.selectionChanged();
      this.openFromAddress();
    },
    // A quiet row-boundary marker follows the position saved for this tab.
    mountBookmark() {
      this.bookmarkMark = document.createElement("div");
      this.bookmarkMark.dataset.bookmarkMarker = "";
      this.bookmarkMark.setAttribute("aria-hidden", "true");
      this.bookmarkMark.style.cssText = "position:absolute;left:8px;z-index:12;pointer-events:none;width:0;height:0";
      const tab = document.createElement("span");
      tab.style.cssText = "position:absolute;left:0;top:0;width:10px;height:10px;background:#fbbf24;border:1px solid #18181bcc;border-radius:1px;transform:translateY(-50%) rotate(45deg);box-shadow:0 1px 2px #0005;opacity:0.85";
      this.bookmarkMark.append(tab);
      this.el.append(this.bookmarkMark);
    },
    beginPositionInput(event) {
      if (event.type === "keydown" && (!/^(ArrowUp|ArrowDown|PageUp|PageDown|Home|End| )$/.test(event.key) || /^(INPUT|TEXTAREA|SELECT)$/.test(event.target?.tagName || "") || event.target?.isContentEditable)) return;
      if (event.type === "pointerdown" && event.clientX < this.el.getBoundingClientRect().right - 16) return;
      this.frozenAnchor = null;
      this.positionInput = true;
      this.extendPositionInput();
    },
    extendPositionInput() {
      clearTimeout(this.positionInputTimer);
      this.positionInputTimer = setTimeout(() => {
        this.positionInput = false;
      }, 250);
    },
    freezePosition() {
      this.positionInput = false;
      clearTimeout(this.positionInputTimer);
      if (!this.frozenAnchor) this.frozenAnchor = this.bookmarkAnchor || this.captureAnchor();
      this.recordPosition("freeze");
    },
    saveBookmark() {
      if (this.frozenAnchor) {
        this.bookmarkAnchor = this.frozenAnchor;
        this.renderBookmark();
        return;
      }
      if (!this.library || !this.sections.length || this.pager) return;
      if (this.bookmarkAnchor && !this.positionInput) {
        this.renderBookmark();
        return;
      }
      if (this.positionInput) this.extendPositionInput();
      this.bookmarkAnchor = this.captureAnchor();
      this.rememberPosition();
      this.renderBookmark();
    },
    bookmarkTop() {
      const a = this.bookmarkAnchor;
      if (!a) return null;
      const index = this.sections.findIndex((s) => s.id === a.id);
      if (index < 0) return null;
      return this.offsets[index] + this.layoutOf(this.sections[index]).mark(a.item, a.rowFraction || 0);
    },
    renderBookmark() {
      if (!this.bookmarkMark) return;
      const top = this.bookmarkTop();
      this.bookmarkMark.style.display = top === null ? "none" : "block";
      if (top !== null) this.bookmarkMark.style.top = `${top}px`;
    },
    // A bounded local trace makes an intermittent wake failure inspectable without
    // recording photos, file URLs, or account details.
    recordPosition(event, details2 = {}) {
      try {
        const key = "phoenix_kit_photos:position_log";
        const entries = JSON.parse(window.sessionStorage.getItem(key) || "[]");
        entries.push({
          event,
          at: Date.now(),
          top: this.el.scrollTop,
          section: this.bookmarkAnchor?.id,
          item: this.bookmarkAnchor?.item,
          frozen: Boolean(this.frozenAnchor),
          ...details2
        });
        window.sessionStorage.setItem(key, JSON.stringify(entries.slice(-40)));
      } catch (_error) {
      }
    },
    positionKey() {
      return `phoenix_kit_photos:position:${this.el.dataset.timelineId}:${this.library}`;
    },
    storedPosition() {
      for (const name of ["sessionStorage", "localStorage"]) {
        try {
          const saved = JSON.parse(window[name].getItem(this.positionKey()));
          const a = saved?.anchor;
          if (a && typeof a.id === "string" && Number.isInteger(a.index) && a.index >= 0 && Number.isFinite(a.item) && a.item >= 0 && Number.isFinite(a.headerOffset) && a.headerOffset >= 0) return saved;
        } catch (_error) {
        }
      }
      return null;
    },
    rememberPosition() {
      if (this.frozenAnchor) return;
      if (!this.library || !this.sections.length) return;
      const value = JSON.stringify({ anchor: this.bookmarkAnchor || this.captureAnchor() });
      for (const name of ["sessionStorage", "localStorage"]) {
        try {
          window[name].setItem(this.positionKey(), value);
        } catch (_error) {
        }
      }
    },
    /** Whether the person is looking at the end of the library, where new photos land. */
    atEnd() {
      const height = totalHeight(this.offsets);
      return height > 0 && this.el.scrollTop + this.el.clientHeight >= height - 24;
    },
    /** Keep the end in view as the library grows: glide there, or jump when motion is unwelcome. */
    followEnd() {
      const top = Math.max(0, totalHeight(this.offsets) - this.el.clientHeight);
      if (this.el.scrollTo && !reducedMotion2()) this.el.scrollTo({ top, behavior: "smooth" });
      else this.el.scrollTop = top;
    },
    /**
     * Ask again for every window held, without letting go of what is shown: the old tiles stay
     * until the new answer replaces them. Requests sent for the old revision would be dropped
     * on arrival, so the ones still in flight are asked again too.
     */
    revalidate() {
      for (const day of this.windows.keys()) {
        this.refreshing.add(day);
        this.send("timeline:need_window", { window: day, revision: this.revision });
      }
    },
    /** Run a deferred refresh once the viewer is closed. */
    applyDeferred() {
      if (!this.deferred) return;
      const payload = this.deferred;
      this.deferred = null;
      this.setIndex(payload);
    },
    measure(section) {
      return this.layoutOf(section).height;
    },
    /** Where everything in a section goes in the style on screen (see layouts.js). */
    layoutOf(section) {
      const { cell, gap, header } = this.metrics;
      const key = `${this.styleId}:${this.columns}:${cell}:${gap}:${header}`;
      if (key !== this.layoutKey || !this.layouts) {
        this.layoutKey = key;
        this.layouts = /* @__PURE__ */ new WeakMap();
      }
      let layout = this.layouts.get(section);
      if (!layout) {
        layout = buildLayout(this.styleId, {
          count: section.count,
          aspectAt: this.aspectReader(section),
          columns: this.columns,
          width: this.columns * (cell + gap) - gap,
          cell,
          gap,
          header
        });
        this.layouts.set(section, layout);
      }
      return layout;
    },
    /** The aspect ratio of each file of a section; the month's average while they are unknown. */
    aspectReader(section) {
      const known = this.aspects?.get(section.id);
      if (known && known.length === section.count) return (index) => known[index];
      const average = section.count > 0 && section.sum_aspect > 0 ? section.sum_aspect / section.count : 1.4;
      return () => average;
    },
    /**
     * Rebuild every offset and restore position by anchor item.
     *
     * Not by scrollTop delta: on a resize every section above the viewport
     * changed height too, so a per-section correction leaves the user
     * somewhere else in their history.
     */
    captureAnchor() {
      const anchor = anchorAt(this.offsets, this.el.scrollTop + this.inset);
      if (!anchor) return null;
      const section = this.sections[anchor.index];
      const { item, fraction } = section ? this.layoutOf(section).anchor(anchor.delta) : { item: 0, fraction: 0 };
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
      };
    },
    /** The height, in px, of what the grid scrolls under: `--photo-timeline-inset-top` (any CSS length). */
    readInset() {
      if (typeof getComputedStyle !== "function") return 0;
      const value = getComputedStyle(this.el).getPropertyValue("--photo-timeline-inset-top").trim();
      if (!value) return 0;
      const probe = document.createElement("div");
      probe.style.cssText = `position:fixed;top:0;left:0;visibility:hidden;pointer-events:none;height:${value}`;
      this.el.appendChild(probe);
      const px2 = probe.offsetHeight;
      probe.remove();
      return px2;
    },
    /**
     * Columns for this width: fixed, or as many tiles of about the target size as fit. A size
     * the person chose by zooming wins over the host's, and may go down to one column.
     */
    columnsFor(width) {
      const { gap } = this.metrics;
      if (this.zoomCell && width > 0) return Math.max(1, Math.round((width + gap) / (this.zoomCell + gap)));
      if (!this.targetCell || width <= 0) return this.baseColumns ?? this.columns;
      return Math.max(3, Math.round((width + gap) / (this.targetCell + gap)));
    },
    relayout(anchor = this.captureAnchor()) {
      this.inset = this.readInset();
      if (this.el.clientWidth > 0) {
        this.columns = this.columnsFor(this.el.clientWidth);
        this.metrics.cell = Math.max(1, (this.el.clientWidth - (this.columns - 1) * this.metrics.gap) / this.columns);
      }
      this.offsets = buildOffsets(this.sections, (s) => this.measure(s), this.inset);
      if (this.spacer) this.spacer.style.height = `${totalHeight(this.offsets)}px`;
      if (anchor && this.sections.length) {
        const found = this.sections.findIndex((s) => s.id === anchor.id);
        const index = found >= 0 ? found : Math.min(anchor.index, this.sections.length - 1);
        const fraction = Number.isFinite(anchor.rowFraction) ? Math.max(0, Math.min(1, anchor.rowFraction)) : 0;
        const unchanged = anchor.columns === this.columns && anchor.cell === this.metrics.cell && anchor.header === this.metrics.header && anchor.gap === this.metrics.gap && (anchor.style ?? DEFAULT_STYLE) === this.styleId;
        const delta = found < 0 ? 0 : unchanged && Number.isFinite(anchor.delta) ? anchor.delta : anchor.headerOffset + this.layoutOf(this.sections[index]).contentY(anchor.item, fraction);
        this.el.scrollTop = Math.max(0, this.offsets[index] + delta - this.inset);
      }
    },
    handleResize() {
      this.relayout();
      this.handleScroll();
    },
    handleScroll() {
      if (this.frozenAnchor && this.sections.length) {
        const before = this.el.scrollTop;
        this.relayout(this.frozenAnchor);
        if (Math.abs(before - this.el.scrollTop) > 1) this.recordPosition("restore", { before });
      }
      const indices = visibleSections(this.offsets, this.el.scrollTop, this.el.clientHeight);
      this.needed = /* @__PURE__ */ new Set();
      for (const i of indices) this.ensureVisibleDays(this.sections[i]);
      for (const day of this.windows.keys()) {
        if (!this.needed.has(day)) {
          this.windows.delete(day);
          this.fetchedAt.delete(day);
        }
      }
      this.materialize(indices);
      this.showCurrent();
      this.saveBookmark();
    },
    /** Put the label of the month at the top of the screen into the host's pill, if it has one. */
    showCurrent() {
      if (!this.current || !this.sections.length) return;
      const index = sectionAtOffset(this.offsets, this.el.scrollTop + this.inset + 1);
      const label = this.sections[index]?.label || "";
      if (this.current.textContent !== label) this.current.textContent = label;
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
      if (this.markNew) this.refreshing.add(day);
      this.send("timeline:need_window", { window: day, revision: this.revision });
    },
    setWindow({ section, items, revision }) {
      if (revision !== this.revision || !this.windows.has(section)) return;
      const arrived = this.refreshing.delete(section);
      this.windows.set(section, items || []);
      this.fetchedAt.set(section, Date.now());
      this.noteArrivals(items || [], arrived);
      this.gliding = arrived;
      this.handleScroll();
      this.gliding = false;
      if (this.drag?.box) this.drawBox();
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
      const now = Date.now();
      for (const [day, items] of this.windows) {
        if (items === null) continue;
        if (now - (this.fetchedAt.get(day) || 0) < olderThan) continue;
        this.send("timeline:need_window", { window: day, revision: this.revision });
      }
    },
    /**
     * A tile's image failed. The likely reason is an expired link, so reload the windows. A burst
     * of failures (a whole screen of tiles) asks once, and a picture that is truly gone cannot
     * start a loop: its new link equals the old one, so it is not requested again.
     */
    imageFailed() {
      const now = Date.now();
      if (now - this.lastReload < RELOAD_EVERY_MS) return;
      this.lastReload = now;
      this.reloadWindows();
    },
    /**
     * Remember the files of a window. When the window was fetched again because storage changed,
     * the ones never seen before are the new photos: they will pop in.
     */
    noteArrivals(items, arrived) {
      for (const item of items) {
        if (arrived && !this.known.has(item.id)) this.fresh.add(item.id);
        this.known.add(item.id);
      }
    },
    /** Jump to a section id, e.g. "2018-07". */
    jumpTo(sectionId) {
      this.frozenAnchor = null;
      this.positionInput = true;
      this.extendPositionInput();
      const index = this.sections.findIndex((s) => s.id === sectionId);
      if (index >= 0) {
        this.el.scrollTop = Math.max(0, this.offsets[index] - this.inset);
        this.handleScroll();
      }
    },
    // --- zoom: pinch, ctrl + wheel (a trackpad pinch), + and - --------------
    storedZoom() {
      try {
        const value = Number(window.localStorage.getItem(ZOOM_KEY));
        return Number.isFinite(value) && value >= MIN_CELL ? value : null;
      } catch (_error) {
        return null;
      }
    },
    rememberZoom() {
      try {
        if (this.zoomCell) window.localStorage.setItem(ZOOM_KEY, String(Math.round(this.zoomCell)));
        else window.localStorage.removeItem(ZOOM_KEY);
      } catch (_error) {
      }
    },
    bindZoom() {
      this.zoomHandlers = [];
      const on = (target, type, fn, options) => {
        target.addEventListener(type, fn, options);
        this.zoomHandlers.push(() => target.removeEventListener(type, fn, options));
      };
      on(this.el, "touchstart", (e) => this.touchStart(e), { passive: true });
      on(this.el, "touchmove", (e) => this.touchMove(e), { passive: false });
      on(this.el, "touchend", (e) => this.touchEnd(e), { passive: true });
      on(this.el, "touchcancel", () => this.endPinch(false), { passive: true });
      on(this.el, "wheel", (e) => this.wheel(e), { passive: false });
      on(this.el, "gesturestart", (e) => this.gesture(e, "start"));
      on(this.el, "gesturechange", (e) => this.gesture(e, "change"));
      on(this.el, "gestureend", (e) => this.gesture(e, "end"));
      on(window, "keydown", (e) => this.zoomKey(e));
    },
    unbindZoom() {
      for (const off of this.zoomHandlers || []) off();
      this.zoomHandlers = [];
      clearTimeout(this.wheelTimer);
    },
    /** The tile under a point of the viewport (x, y from its top-left), as a section and a place in it. */
    itemAtPoint(x, y) {
      if (!this.sections.length) return null;
      const index = sectionAtOffset(this.offsets, this.el.scrollTop + y);
      const section = this.sections[index];
      if (!section || section.count <= 0) return null;
      return { index, item: this.layoutOf(section).hit(x, this.el.scrollTop + y - this.offsets[index]) };
    },
    /** The smallest and largest tile there can be at this width: MIN_CELL, and one column. */
    cellLimits() {
      return [MIN_CELL, Math.max(MIN_CELL, this.el.clientWidth)];
    },
    /**
     * Make tiles `cell` px (about: the columns are a whole number), keeping the photo that
     * is under (x, y) where it is on screen.
     */
    zoomTo(cell, x, y) {
      this.beginPositionInput({ type: "wheel" });
      const [low, high] = this.cellLimits();
      const focus = this.itemAtPoint(x, y);
      this.zoomCell = Math.min(high, Math.max(low, cell));
      this.relayout(null);
      if (focus) this.el.scrollTop = Math.max(0, this.tileMiddle(focus) - y);
      this.handleScroll();
      this.rememberZoom();
    },
    /** The height in the library of the middle of a tile. */
    tileMiddle({ index, item }) {
      const { y, h } = this.layoutOf(this.sections[index]).rect(item);
      return this.offsets[index] + y + h / 2;
    },
    /** One column more (`steps` > 0, smaller tiles) or fewer, around the middle of the screen. */
    stepZoom(steps) {
      const width = this.el.clientWidth;
      if (!(width > 0)) return;
      const columns2 = Math.max(1, this.columns + steps);
      const { gap } = this.metrics;
      this.zoomTo((width - (columns2 - 1) * gap) / columns2, width / 2, this.el.clientHeight / 2);
    },
    zoomKey(event) {
      if (this.pager || event.metaKey || event.ctrlKey || event.altKey) return;
      const target = event.target;
      if (target && /^(input|select|textarea)$/i.test(target.tagName || "")) return;
      if (target && target.isContentEditable) return;
      if (event.key === "+" || event.key === "=") this.stepZoom(-1);
      else if (event.key === "-" || event.key === "_") this.stepZoom(1);
      else if (event.key === "0") this.resetZoom();
      else return;
      event.preventDefault();
    },
    /** Back to the size the host asks for. */
    resetZoom() {
      this.beginPositionInput({ type: "wheel" });
      this.zoomCell = null;
      this.rememberZoom();
      this.relayout();
      this.handleScroll();
    },
    /**
     * While the fingers are down the grid is only scaled on the screen (a transform: cheap and
     * smooth). When they lift, the scale becomes a tile size, and the grid is laid out again.
     */
    previewScale(scale, x, y) {
      if (!this.layer) return;
      this.layer.style.transformOrigin = `${x}px ${this.el.scrollTop + y}px`;
      this.layer.style.transform = scale === 1 ? "" : `scale(${scale})`;
    },
    /** A scale that would take the tiles beyond what they can be is held back, with some give. */
    clampScale(scale) {
      const [low, high] = this.cellLimits();
      const cell = this.metrics.cell;
      return Math.min(high / cell, Math.max(low / cell, scale));
    },
    startPinch(x, y) {
      if (!this.pinch) this.pinch = { scale: 1, x, y };
      this.pinch.x = x;
      this.pinch.y = y;
    },
    movePinch(scale, x, y) {
      if (!this.pinch) this.startPinch(x, y);
      this.pinch.scale = this.clampScale(scale);
      this.pinch.x = x;
      this.pinch.y = y;
      this.previewScale(this.pinch.scale, x, y);
    },
    endPinch(commit = true) {
      const pinch = this.pinch;
      this.pinch = null;
      if (!pinch) return;
      this.previewScale(1, pinch.x, pinch.y);
      if (commit && Math.abs(pinch.scale - 1) > 0.02) {
        this.zoomTo(this.metrics.cell * pinch.scale, pinch.x, pinch.y);
      }
    },
    touchStart(event) {
      if (event.touches.length === 2) {
        const [a, b] = event.touches;
        this.touchBase = distance(a, b);
        this.pinch = null;
      } else {
        this.touchBase = null;
      }
    },
    touchMove(event) {
      if (event.touches.length !== 2 || !this.touchBase) return;
      event.preventDefault();
      const [a, b] = event.touches;
      const box = this.el.getBoundingClientRect();
      this.movePinch(
        distance(a, b) / this.touchBase,
        (a.clientX + b.clientX) / 2 - box.left,
        (a.clientY + b.clientY) / 2 - box.top
      );
    },
    touchEnd(event) {
      if (event.touches.length < 2 && this.pinch) {
        this.touchBase = null;
        this.endPinch();
      }
    },
    wheel(event) {
      if (!event.ctrlKey) return;
      event.preventDefault();
      const box = this.el.getBoundingClientRect();
      const x = event.clientX - box.left;
      const y = event.clientY - box.top;
      const scale = (this.pinch ? this.pinch.scale : 1) * Math.exp(-event.deltaY * 0.01);
      this.movePinch(scale, x, y);
      clearTimeout(this.wheelTimer);
      this.wheelTimer = setTimeout(() => this.endPinch(), 140);
    },
    gesture(event, phase) {
      event.preventDefault();
      if (this.touchBase) return;
      const box = this.el.getBoundingClientRect();
      const x = (event.clientX ?? box.left + box.width / 2) - box.left;
      const y = (event.clientY ?? box.top + box.height / 2) - box.top;
      if (phase === "start") this.startPinch(x, y);
      else if (phase === "change") this.movePinch(event.scale, x, y);
      else this.endPinch();
    },
    // --- the swipe viewer ------------------------------------------------
    /** The engine the host asked for (`pager` on the component), or null: the host's own viewer. */
    pagerEngine() {
      const root = this.el.closest(".phoenix-kit-photo-timeline");
      return root ? engineFor(root.dataset.pager) : null;
    },
    pagerEnabled() {
      return this.pagerEngine() !== null;
    },
    /** Every position the index lists, from the first section's first file, and where each section starts. */
    resetSlides() {
      this.slides = new SlideStore(this.sections);
      this.sectionStarts = [];
      let start = 0;
      for (const section of this.sections) {
        this.sectionStarts.push(start);
        start += (section.days_list || []).reduce((sum, day) => sum + (day.count || 0), 0);
      }
      this.pendingOpen = null;
      if (this.pager && this.pager.destroy) {
        this.addressClosing = true;
        this.pager.destroy();
      }
    },
    prefetchSlides(center, radius = 8) {
      if (!this.pagerEnabled() || !Number.isFinite(center)) return;
      for (const block of this.slides.missing(center, radius)) {
        this.slides.markAsked(block);
        this.send("timeline:slides", {
          window: block.window,
          from: block.from,
          count: block.count,
          want: wantWidth(window),
          revision: this.revision
        });
      }
    },
    setSlides({ window: day, from, items, error, revision }) {
      if (revision !== this.revision) return;
      if (error) {
        this.slides.forget(day, from);
        return;
      }
      const added = this.slides.put(day, from, items || []);
      if (this.pager && this.pager.isOpen) this.pager.refresh(added);
      if (this.pendingOpen !== null && this.slides.has(this.pendingOpen)) {
        const index = this.pendingOpen;
        this.pendingOpen = null;
        clearTimeout(this.openTimer);
        this.openPager(index);
      }
    },
    /** A tile was clicked: the swipe viewer when the host asked for it, else the host's own. */
    openTile(id, global) {
      if (!this.pagerEnabled() || !Number.isFinite(global)) {
        this.send("timeline:open", { id });
        return;
      }
      if (this.slides.has(global)) {
        this.openPager(global);
        return;
      }
      this.pendingOpen = global;
      this.prefetchSlides(global);
      clearTimeout(this.openTimer);
      this.openTimer = setTimeout(() => {
        if (this.pendingOpen === global) {
          this.pendingOpen = null;
          this.send("timeline:open", { id });
        }
      }, 4e3);
    },
    // The engine is loaded when first used; esbuild keeps it in the one bundle, and
    // the import keeps this file loadable without a bundler (the unit tests).
    async openPager(index) {
      if (this.pager) return;
      const id = this.pagerEngine();
      if (!id) return;
      this.prefetchSlides(index);
      this.pager = true;
      let Engine;
      try {
        Engine = await loadEngine(id);
      } catch (error) {
        this.pager = null;
        console.error("PhotoTimeline: the viewer engine did not load", id, error);
        this.applyDeferred();
        const slide = this.slides.get(index);
        if (slide) this.send("timeline:open", { id: slide.id });
        return;
      }
      this.video = this.video || new VideoController();
      this.pager = new Engine({
        store: this.slides,
        video: this.video,
        thumbOf: (slideId) => this.thumbOf(slideId),
        tileImage: (i) => this.tileImage(i),
        onInfo: (slideId) => this.send("timeline:open", { id: slideId }),
        onChange: (i) => {
          this.prefetchSlides(i);
          this.reveal(i);
          this.syncAddress(i);
        },
        onClose: () => {
          this.pager = null;
          this.applyDeferred();
          this.leaveAddress();
        }
      });
      this.pager.open(index);
      this.syncAddress(index);
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
      const root = this.el.closest(".phoenix-kit-photo-timeline");
      const photo = root && root.dataset.photoPath;
      const library = root && root.dataset.libraryPath;
      return photo && library && photo.includes(":code") ? { photo, library } : null;
    },
    /** Whether the page is at the address of some photo. */
    atPhotoAddress(paths) {
      const [before, after] = paths.photo.split(":code");
      const path = window.location.pathname;
      return path.startsWith(before) && path.endsWith(after) && path.length > before.length + after.length;
    },
    /**
     * The viewer shows slide `index`: put the photo's address in the bar. The first call after
     * the viewer opened adds a history entry (unless the page was opened on this photo already),
     * the rest replace it.
     */
    syncAddress(index) {
      const paths = this.addresses();
      const slide = this.slides.get(index);
      if (!paths || !slide || !slide.code) return;
      const to = paths.photo.replace(":code", encodeURIComponent(slide.code));
      this.noteSent(slide.id);
      if (window.location.pathname === to) {
        this.addressOpen = true;
        return;
      }
      const push = !this.atPhotoAddress(paths);
      if (!this.addressOpen) this.addressHistoryId = window.history.state?.id || null;
      this.addressOpen = true;
      if (push) this.addressPushed = true;
      this.js().patch(to, { replace: !push });
    },
    /** Remember that the address of this photo was just set, for `applyView` to recognise the echo. */
    noteSent(id) {
      const now = Date.now();
      const sent = this.addressSent = this.addressSent || /* @__PURE__ */ new Map();
      for (const [other, at] of sent) if (now - at > ECHO_MS) sent.delete(other);
      sent.set(id, now);
    },
    /**
     * The viewer is gone. Unless the server closed it (Back), the address leaves the photo: back
     * to the entry before it when the viewer added one, else the library's address in its place.
     */
    leaveAddress() {
      const paths = this.addresses();
      const server = this.addressClosing;
      const pushed = this.addressPushed;
      const sameView = this.addressHistoryId !== null && this.addressHistoryId === window.history.state?.id;
      this.addressClosing = false;
      this.addressOpen = false;
      this.addressPushed = false;
      this.addressHistoryId = null;
      if (!paths || server || !this.atPhotoAddress(paths)) return;
      if (pushed && sameView) window.history.back();
      else this.js().patch(paths.library, { replace: true });
    },
    /** The host says which photo its address names: `{ id, global }`, or `{ id: null }` for none. */
    applyView(payload) {
      if (!this.addresses()) return;
      const { id, global } = payload || {};
      if (!id) {
        this.view = null;
        if (this.pager && this.pager !== true) {
          this.addressClosing = true;
          this.pager.close();
        }
        return;
      }
      const at = this.addressSent && this.addressSent.get(id);
      if (this.pager && at && Date.now() - at < ECHO_MS) return;
      this.view = { id, global };
      this.openFromAddress();
    },
    /** Open or turn the viewer to the photo the address names, once there is an index to place it in. */
    openFromAddress() {
      const view = this.view;
      if (!view || !this.pagerEnabled() || !Number.isFinite(view.global) || !this.sections.length) return;
      if (this.pager === true) return;
      this.view = null;
      if (this.pager) {
        const slide = this.slides.get(this.pager.index);
        if (slide && slide.id === view.id) return;
        if (this.pager.goTo) this.pager.goTo(view.global);
        return;
      }
      this.addressOpen = true;
      this.openPager(view.global);
    },
    thumbOf(id) {
      const node = this.pool.get(id);
      const img = node && node.querySelector("img");
      return img ? img.currentSrc || img.src : void 0;
    },
    tileImage(index) {
      const slide = this.slides.get(index);
      const node = slide && this.pool.get(slide.id);
      return node ? node.querySelector("img") : null;
    },
    /** Scroll the grid so the tile of `index` is on screen, for the viewer to fly back to. */
    reveal(index) {
      let found = -1;
      for (let i = 0; i < this.sectionStarts.length; i++) {
        if (this.sectionStarts[i] <= index) found = i;
        else break;
      }
      if (found < 0) return;
      const rect = this.layoutOf(this.sections[found]).rect(index - this.sectionStarts[found]);
      const top = this.offsets[found] + rect.y;
      const view = this.el.clientHeight;
      if (top < this.el.scrollTop + this.inset || top + rect.h > this.el.scrollTop + view) {
        this.el.scrollTop = Math.max(0, top - this.inset - (view - this.inset - rect.h) / 2);
        this.handleScroll();
      }
    },
    visibleItemRange(section) {
      const sectionIndex = this.sections.indexOf(section);
      if (sectionIndex < 0 || !section || section.count <= 0) return { first: 0, last: -1 };
      const top = this.offsets[sectionIndex];
      const viewTop = this.el.scrollTop;
      return this.layoutOf(section).range(viewTop - top, viewTop + this.el.clientHeight - top);
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
          wanted.push({
            item,
            global: this.sectionStarts[sectionIndex] + index,
            ...this.tilePosition(sectionIndex, index)
          });
        }
      }
      for (const [id, node] of this.pool) {
        if (!keep.has(id)) {
          if (this.leaving && !id.startsWith("header:")) this.leaving.set(id, node);
          else node.remove();
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
        node.className = this.fill ? "pkt-header pointer-events-none px-3 text-base font-semibold" : "pkt-header pointer-events-none px-1 text-sm font-semibold";
        node.append(document.createElement("span"));
        if (this.selectable()) {
          const check = document.createElement("button");
          check.type = "button";
          check.className = "pkt-section-check";
          check.dataset.sectionSelect = "";
          check.setAttribute("aria-label", this.root()?.dataset.selectMonthLabel || "Select month");
          check.addEventListener("click", () => this.selectSection(this.sections.indexOf(section)));
          node.append(check);
        }
        this.layer.appendChild(node);
        this.pool.set(id, node);
      }
      node.firstChild.textContent = section.label || section.id;
      const top = this.offsets[sectionIndex];
      if (this.gliding) glide(node, 0, top);
      node.style.position = "absolute";
      node.style.left = "0";
      node.style.top = `${top}px`;
      node.style.height = `${this.metrics.header}px`;
      node.style.lineHeight = `${this.metrics.header}px`;
    },
    tilePosition(sectionIndex, index) {
      const { x, y, w, h } = this.layoutOf(this.sections[sectionIndex]).rect(index);
      return { x, y: this.offsets[sectionIndex] + y, w, h };
    },
    placeTile({ item, x, y, w, h, global }) {
      let node = this.pool.get(item.id);
      const created = !node;
      if (!node) {
        node = document.createElement("button");
        node.type = "button";
        node.dataset.fileId = item.id;
        node.setAttribute("aria-label", item.kind === "video" ? "Open video" : "Open photo");
        node.className = "pkt-tile";
        node.addEventListener("pointerdown", () => this.prefetchSlides(Number(node.dataset.global)));
        node.addEventListener("click", (event) => this.tileClick(event, node, item.id));
        fillTile(node, item);
        this.layer.appendChild(node);
        this.pool.set(item.id, node);
      } else if (this.gliding && parseFloat(node.style.width) === w && parseFloat(node.style.height) === h) {
        glide(node, x, y);
      }
      node.dataset.global = String(global);
      node.toggleAttribute("data-selected", this.isSelected(item.id));
      node.style.position = "absolute";
      node.style.left = `${x}px`;
      node.style.top = `${y}px`;
      node.style.width = `${w}px`;
      node.style.height = `${h}px`;
      const img = node.querySelector("img:last-of-type");
      const src = pickSource(item, w, h, this.style(), devicePixels());
      if (img && src && img.dataset.src !== src) {
        if (!created && img.dataset.src && this.sharpening(img.dataset.src, item)) swapImage(node, img, src);
        else {
          img.dataset.src = src;
          img.src = src;
        }
      } else if (img && !src) {
        img.removeAttribute("src");
        delete img.dataset.src;
      }
      if (created && this.fresh.delete(item.id)) popIn(node);
    },
    /** Whether changing from `old` is a change of picture, not a link that ran out being renewed. */
    sharpening(old, item) {
      return [item.thumb, item.fit, item.preview, item.large].includes(old);
    },
    // --- styles: how the tiles look, and the walk from one look to another ---
    style() {
      return STYLES[this.styleId] || STYLES[DEFAULT_STYLE];
    },
    /** What the person picked last, else what the host asks for, else the plain grid. */
    startingStyle() {
      let stored = null;
      try {
        stored = window.localStorage.getItem(STYLE_KEY);
      } catch (_error) {
      }
      if (STYLES[stored]) return stored;
      const asked = this.el.dataset.style;
      return STYLES[asked] ? asked : DEFAULT_STYLE;
    },
    rememberStyle() {
      try {
        window.localStorage.setItem(STYLE_KEY, this.styleId);
      } catch (_error) {
      }
    },
    /** Tell the server on hello whether this style needs the aspect ratios with the index. */
    readyPayload() {
      return this.style().aspects ? { aspects: true } : {};
    },
    storeAspects(aspects) {
      if (!aspects) return;
      this.aspects = this.aspects || /* @__PURE__ */ new Map();
      for (const [id, bytes] of Object.entries(aspects)) this.aspects.set(id, decodeAspects(bytes));
      this.layouts = null;
    },
    /** The ratios arrived on their own: for a style waiting on them, or to replace averages. */
    setAspects({ aspects, revision }) {
      if (revision !== this.revision) return;
      this.storeAspects(aspects);
      clearTimeout(this.aspectsTimer);
      if (this.pendingStyle) {
        const id = this.pendingStyle;
        this.pendingStyle = null;
        this.morphTo(id);
      } else if (this.style().aspects) {
        this.relayout();
        this.handleScroll();
      }
    },
    hasAspects() {
      return this.sections.every((s) => this.aspects?.get(s.id)?.length === s.count);
    },
    /** Change style. One that shows whole photos first asks for the ratios it is placed by. */
    setStyle(id) {
      if (!STYLES[id]) return;
      this.pendingStyle = null;
      clearTimeout(this.aspectsTimer);
      this.markStyle(id);
      this.toggleStyleMenu(false);
      if (id === this.styleId) return;
      if (STYLES[id].aspects && !this.hasAspects()) {
        this.pendingStyle = id;
        this.send("timeline:aspects", { revision: this.revision });
        this.aspectsTimer = setTimeout(() => {
          const waiting = this.pendingStyle;
          this.pendingStyle = null;
          if (waiting) this.morphTo(waiting);
        }, ASPECTS_WAIT_MS);
        return;
      }
      this.morphTo(id);
    },
    /**
     * Walk the tiles from this style to `id`: the photo in the middle of the screen stays there,
     * and every tile goes from where it was to where it belongs (see morph.js).
     */
    morphTo(id) {
      const height = this.el.clientHeight;
      const focus = this.sections.length ? this.itemAtPoint(this.el.clientWidth / 2, height / 2) : null;
      const spot = focus ? this.tileMiddle(focus) - this.el.scrollTop : height / 2;
      const before = this.geometry();
      const from = /* @__PURE__ */ new Map();
      for (const [key, node] of this.pool) {
        if (!key.startsWith("header:")) from.set(key, rectOf(node));
      }
      this.styleId = id;
      this.el.dataset.activeStyle = id;
      this.rememberStyle();
      this.beginPositionInput({ type: "wheel" });
      this.relayout(null);
      if (focus) this.el.scrollTop = Math.max(0, this.tileMiddle(focus) - spot);
      this.leaving = /* @__PURE__ */ new Map();
      this.handleScroll();
      const leaving = this.leaving;
      this.leaving = null;
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
      });
    },
    /** What it takes to place a tile in the style on screen, for when the style has changed. */
    geometry() {
      const layouts = this.sections.map((section) => this.layoutOf(section));
      return { layouts, offsets: this.offsets, starts: this.sectionStarts, scrollTop: this.el.scrollTop };
    },
    /** Where the file at position `global` of the library goes in a `geometry()`. */
    rectIn({ layouts, offsets, starts }, global) {
      let found = -1;
      for (let i = 0; i < starts.length && starts[i] <= global; i++) found = i;
      if (found < 0 || !layouts[found] || global - starts[found] >= layouts[found].count) return null;
      const rect = layouts[found].rect(global - starts[found]);
      return { ...rect, y: offsets[found] + rect.y };
    },
    /** Show which style is on, in the component's menu. */
    markStyle(id) {
      const root = this.el.closest?.(".phoenix-kit-photo-timeline");
      if (!root) return;
      for (const button of root.querySelectorAll("[data-style-pick]")) {
        button.setAttribute("aria-pressed", String(button.dataset.stylePick === id));
      }
      const icon = root.querySelector("[data-style-current]");
      const picked = root.querySelector(`[data-style-pick="${id}"] svg`);
      if (icon && picked) icon.replaceChildren(picked.cloneNode(true));
    },
    toggleStyleMenu(open) {
      const root = this.el.closest?.(".phoenix-kit-photo-timeline");
      const menu = root?.querySelector("[data-style-menu]");
      const toggle = root?.querySelector("[data-style-toggle]");
      if (!menu || !toggle) return;
      const show = open ?? menu.hidden;
      menu.hidden = !show;
      toggle.setAttribute("aria-expanded", String(show));
    },
    /** The menu is the component's markup; every click on it is handled here, in the browser. */
    bindStyleMenu() {
      const root = this.el.closest?.(".phoenix-kit-photo-timeline");
      if (!root) return;
      this.onStyleClick = (event) => {
        const pick = event.target.closest?.("[data-style-pick]");
        if (pick) {
          this.setStyle(pick.dataset.stylePick);
        } else if (event.target.closest?.("[data-style-toggle]")) {
          this.toggleStyleMenu();
        } else if (!event.target.closest?.("[data-style-menu]")) {
          this.toggleStyleMenu(false);
        }
      };
      this.onStyleKey = (event) => this.styleKey(event);
      document.addEventListener("click", this.onStyleClick);
      window.addEventListener("keydown", this.onStyleKey);
      this.markStyle(this.styleId);
    },
    unbindStyleMenu() {
      if (this.onStyleClick) document.removeEventListener("click", this.onStyleClick);
      if (this.onStyleKey) window.removeEventListener("keydown", this.onStyleKey);
    },
    /** `v` walks through the styles, Shift+`v` back, and Escape closes the menu. */
    styleKey(event) {
      if (event.key === "Escape") this.toggleStyleMenu(false);
      if (this.pager || event.metaKey || event.ctrlKey || event.altKey) return;
      if (event.key !== "v" && event.key !== "V") return;
      const target = event.target;
      if (target && (/^(input|select|textarea)$/i.test(target.tagName || "") || target.isContentEditable)) return;
      const step = event.shiftKey ? -1 : 1;
      const at = STYLE_IDS.indexOf(this.pendingStyle || this.styleId);
      this.setStyle(STYLE_IDS[(at + step + STYLE_IDS.length) % STYLE_IDS.length]);
      event.preventDefault();
    }
  };
  function rectOf(node) {
    return {
      x: parseFloat(node.style.left) || 0,
      y: parseFloat(node.style.top) || 0,
      w: parseFloat(node.style.width) || 0,
      h: parseFloat(node.style.height) || 0
    };
  }
  function devicePixels() {
    return typeof window !== "undefined" ? Math.min(2, window.devicePixelRatio || 1) : 1;
  }
  function glide(node, x, y) {
    if (reducedMotion2() || !node.animate) return;
    const dx = (parseFloat(node.style.left) || 0) - x;
    const dy = (parseFloat(node.style.top) || 0) - y;
    if (!dx && !dy) return;
    node.animate(
      [{ transform: `translate(${dx}px, ${dy}px)` }, { transform: "translate(0, 0)" }],
      { duration: 260, easing: "cubic-bezier(0.2, 0.8, 0.2, 1)" }
    );
  }
  function popIn(node) {
    if (reducedMotion2() || !node.animate) return;
    node.animate(
      [
        { opacity: 0, transform: "scale(0.8)" },
        { opacity: 1, transform: "scale(1)" }
      ],
      { duration: 420, easing: "cubic-bezier(0.34, 1.56, 0.64, 1)" }
    );
  }
  function reducedMotion2() {
    return typeof window !== "undefined" && window.matchMedia ? window.matchMedia("(prefers-reduced-motion: reduce)").matches : false;
  }
  function distance(a, b) {
    return Math.hypot(a.clientX - b.clientX, a.clientY - b.clientY);
  }
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

  // js/drop_files.js
  function carriesFiles(dataTransfer) {
    const types = dataTransfer && dataTransfer.types ? Array.from(dataTransfer.types) : [];
    return types.includes("Files");
  }
  function extensionOf(name) {
    const i = String(name || "").lastIndexOf(".");
    return i > 0 ? name.slice(i).toLowerCase() : "";
  }
  function isHidden(name) {
    const n = String(name || "");
    return n.startsWith(".") || n === "Thumbs.db" || n === "desktop.ini";
  }
  function acceptable(name, accept) {
    if (isHidden(name)) return false;
    if (!accept || accept.length === 0) return true;
    return accept.includes(extensionOf(name));
  }
  var fileOf = (entry) => new Promise((resolve, reject) => entry.file(resolve, reject));
  async function readAll(reader) {
    const all = [];
    for (; ; ) {
      const batch = await new Promise((resolve, reject) => reader.readEntries(resolve, reject));
      if (!batch || batch.length === 0) return all;
      all.push(...batch);
    }
  }
  async function walk(entry, out, accept, state) {
    if (state.count >= state.limit) {
      state.truncated = true;
      return;
    }
    if (entry.isFile) {
      if (isHidden(entry.name)) return;
      let file;
      try {
        file = await fileOf(entry);
      } catch (_error) {
        state.skipped++;
        return;
      }
      if (acceptable(file.name, accept)) {
        out.push(file);
        state.count++;
      } else {
        state.skipped++;
      }
    } else if (entry.isDirectory) {
      if (isHidden(entry.name)) return;
      let children;
      try {
        children = await readAll(entry.createReader());
      } catch (_error) {
        state.unreadable++;
        return;
      }
      for (const child of children) await walk(child, out, accept, state);
    }
  }
  async function filesFromDrop(dataTransfer, { accept = null, limit = 2e4 } = {}) {
    const items = dataTransfer && dataTransfer.items ? Array.from(dataTransfer.items) : [];
    const entries = [];
    const plain = [];
    for (const item of items) {
      if (item.kind !== "file") continue;
      const entry = typeof item.webkitGetAsEntry === "function" ? item.webkitGetAsEntry() : null;
      if (entry) entries.push(entry);
      else {
        const file = item.getAsFile && item.getAsFile();
        if (file) plain.push(file);
      }
    }
    if (items.length === 0 && dataTransfer && dataTransfer.files) plain.push(...Array.from(dataTransfer.files));
    const state = { skipped: 0, unreadable: 0, count: 0, limit, truncated: false };
    const files = [];
    for (const file of plain) {
      if (acceptable(file.name, accept)) {
        files.push(file);
        state.count++;
      } else state.skipped++;
    }
    for (const entry of entries) await walk(entry, files, accept, state);
    return { files, skipped: state.skipped, unreadable: state.unreadable, truncated: state.truncated };
  }

  // js/photo_uploader.js
  var CONCURRENCY_KEY = "phoenix_kit_photos:upload_concurrency";
  var MAX_QUEUED_NAMES = 50;
  var PhotoUploader = {
    mounted() {
      this.name = this.el.dataset.uploadName || "photos";
      this.accept = parseList(this.el.dataset.accept);
      this.batch = Math.max(1, parseInt(this.el.dataset.batch || "100", 10) || 100);
      this.maxConcurrency = Math.max(1, parseInt(this.el.dataset.concurrencyMax || "8", 10) || 8);
      this.concurrency = this.readConcurrency();
      this.gated = this.el.dataset.auto === "false";
      this.started = !this.gated;
      this.onSubmit = () => {
        this.started = true;
      };
      this.el.addEventListener("submit", this.onSubmit);
      this.queue = [];
      this.draining = false;
      this.gone = false;
      this.depth = 0;
      this.dragging = false;
      this.onConcurrencyChange = (event) => {
        const target = event.target;
        if (target && target.closest && target.closest("[data-concurrency-select]")) {
          this.setConcurrency(target.value);
        }
      };
      this.el.addEventListener("change", this.onConcurrencyChange);
      this.onInputChange = (event) => {
        const input = event.target;
        if (!input || !input.matches || !input.matches("input[type=file]")) return;
        if (!input.files || input.files.length === 0) return;
        event.preventDefault();
        event.stopPropagation();
        const files = Array.from(input.files);
        input.value = "";
        this.takeFiles(files);
      };
      this.el.addEventListener("input", this.onInputChange, true);
      this.el.addEventListener("change", this.onInputChange, true);
      this.onClick = (event) => {
        const target = event.target;
        if (target && target.closest && target.closest("[data-cancel-all]")) this.queue = [];
      };
      this.el.addEventListener("click", this.onClick);
      const onInput = (event) => event.target && event.target.closest && event.target.closest("input[type=file]");
      this.onEnter = (event) => {
        if (!carriesFiles(event.dataTransfer)) return;
        this.depth += 1;
        this.setDragging(true);
      };
      this.onOver = (event) => {
        if (!carriesFiles(event.dataTransfer) || onInput(event)) return;
        event.preventDefault();
        event.dataTransfer.dropEffect = "copy";
      };
      this.onLeave = (event) => {
        if (!carriesFiles(event.dataTransfer)) return;
        this.depth = Math.max(0, this.depth - 1);
        if (this.depth === 0) this.setDragging(false);
      };
      this.onDrop = (event) => {
        if (!carriesFiles(event.dataTransfer) || onInput(event)) return;
        event.preventDefault();
        this.depth = 0;
        this.setDragging(false);
        this.take(event.dataTransfer);
      };
      window.addEventListener("dragenter", this.onEnter);
      window.addEventListener("dragover", this.onOver);
      window.addEventListener("dragleave", this.onLeave);
      window.addEventListener("drop", this.onDrop);
    },
    // LiveView patches the element back to what the server rendered, which has no
    // `data-active` (the drag is still going on) and the control's default selection.
    updated() {
      this.paint();
      const gated = this.el.dataset.auto === "false";
      if (gated !== this.gated) {
        this.gated = gated;
        this.started = !gated;
      }
      const select = this.el.querySelector("[data-concurrency-select]");
      if (select) select.value = String(this.concurrency);
    },
    destroyed() {
      this.gone = true;
      window.removeEventListener("dragenter", this.onEnter);
      window.removeEventListener("dragover", this.onOver);
      window.removeEventListener("dragleave", this.onLeave);
      window.removeEventListener("drop", this.onDrop);
      this.el.removeEventListener("change", this.onConcurrencyChange);
      this.el.removeEventListener("input", this.onInputChange, true);
      this.el.removeEventListener("change", this.onInputChange, true);
      this.el.removeEventListener("click", this.onClick);
      this.el.removeEventListener("submit", this.onSubmit);
    },
    // The control's value: a saved choice, else the server's default, clamped to
    // [1, maxConcurrency]. Never above the batch, or LiveView would refuse the entries.
    readConcurrency() {
      let saved = NaN;
      try {
        saved = parseInt(window.localStorage.getItem(CONCURRENCY_KEY) || "", 10);
      } catch (_error) {
      }
      const fallback = parseInt(this.el.dataset.concurrency || "", 10);
      const base = !isNaN(saved) ? saved : !isNaN(fallback) ? fallback : 4;
      return clamp2(base, 1, Math.min(this.maxConcurrency, this.batch));
    },
    setConcurrency(value) {
      this.concurrency = clamp2(parseInt(value, 10) || 4, 1, Math.min(this.maxConcurrency, this.batch));
      try {
        window.localStorage.setItem(CONCURRENCY_KEY, String(this.concurrency));
      } catch (_error) {
      }
      const select = this.el.querySelector("[data-concurrency-select]");
      if (select) select.value = String(this.concurrency);
    },
    setDragging(on) {
      this.dragging = on;
      this.paint();
    },
    paint() {
      const overlay = this.el.querySelector("[data-drop-overlay]");
      if (!overlay) return;
      if (this.dragging) overlay.setAttribute("data-active", "");
      else overlay.removeAttribute("data-active");
    },
    // Called inside the drop event: `filesFromDrop` collects the entries before its
    // first await, which is the only moment the browser lets it.
    take(dataTransfer) {
      filesFromDrop(dataTransfer, { accept: this.accept }).then(({ files, skipped, unreadable, truncated }) => {
        this.takeFiles(files, { skipped, unreadable, truncated });
      });
    },
    // Files from a drop or the picker: told to the component (it opens the panel and says
    // what was left out), queued, and drained through the concurrency window.
    takeFiles(files, counts = {}) {
      if (this.gated && files.length > 0) this.started = false;
      this.pushEventTo(this.el, "dropped", {
        files: files.length,
        skipped: counts.skipped || 0,
        unreadable: counts.unreadable || 0,
        truncated: counts.truncated === true
      });
      this.queue.push(...files);
      return this.drain();
    },
    // What the panel shows beyond the entries in flight: the count of files still queued,
    // and the first few names, so the whole selection is listed.
    waitingPayload() {
      return {
        count: this.queue.length,
        names: this.queue.slice(0, MAX_QUEUED_NAMES).map((f) => String(f.name).slice(0, 255))
      };
    },
    // Sends the queue on, keeping at most `this.concurrency` files in flight: whenever the
    // server says a slot freed up, that many more are handed to LiveView. In a public
    // library nothing is sent until Upload was pressed. A server that answers without
    // `in_flight` (an older one) falls back to the old batch behaviour.
    async drain() {
      if (this.draining) return;
      this.draining = true;
      try {
        while (this.queue.length > 0 && !this.gone) {
          const state = await this.ready();
          const inFlight = state && Number.isInteger(state.inFlight) ? state.inFlight : null;
          if (inFlight !== null && !this.gone) {
            const limit = this.gated && !this.started ? 0 : this.concurrency;
            const room = Math.max(0, Math.min(limit - inFlight, this.batch - inFlight));
            if (room > 0) {
              const next = this.queue.slice(0, room);
              this.queue = this.queue.slice(next.length);
              this.uploadTo(this.el, this.name, next);
            }
            this.pushEventTo(this.el, "waiting", this.waitingPayload());
            await sleep(500);
          } else {
            if (state.idle && !this.gone) {
              const next = this.queue.slice(0, this.batch);
              this.queue = this.queue.slice(next.length);
              this.uploadTo(this.el, this.name, next);
            }
            this.pushEventTo(this.el, "waiting", this.waitingPayload());
            await sleep(state.idle ? 300 : 500);
          }
        }
      } finally {
        this.draining = false;
      }
    },
    // How many entries the component still has in flight (uploading, or waiting for a
    // click in a public library). No answer in five seconds (a lost connection) counts as
    // a full window, and `in_flight` comes back null so the drain falls back to batches.
    ready() {
      return new Promise((resolve) => {
        const timer = setTimeout(() => resolve({ idle: false, inFlight: null }), 5e3);
        this.pushEventTo(this.el, "ready", {}, (reply) => {
          clearTimeout(timer);
          const inFlight = reply && Number.isInteger(reply.in_flight) ? reply.in_flight : null;
          resolve({ idle: Boolean(reply && reply.idle), inFlight });
        });
      });
    }
  };
  var sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
  var clamp2 = (n, low, high) => Math.min(Math.max(isNaN(n) ? low : n, low), high);
  function parseList(json) {
    try {
      const list = JSON.parse(json || "[]");
      return Array.isArray(list) ? list.map(String) : [];
    } catch (_error) {
      return [];
    }
  }

  // js/index.js
  if (typeof window !== "undefined") installViewerWarm(window);
  return __toCommonJS(index_exports);
})();
/*! Bundled license information:

photoswipe/dist/photoswipe.esm.js:
  (*!
    * PhotoSwipe 5.4.4 - https://photoswipe.com
    * (c) 2024 Dmytro Semenov
    *)
*/
window.PhoenixKitPhotosHooks=PhoenixKitPhotosHooks;
