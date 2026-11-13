import PhotoSwipe from "photoswipe"
import photoswipeCss from "photoswipe/dist/photoswipe.css"
import { dialogOpen } from "./engine.js"
import { inPanel, typing, viewportBesidePanel } from "../info_panel.js"
import { SHARED_CSS, addStyle } from "./video.js"

// The PhotoSwipe engine (see engine.js for the contract): PhotoSwipe is the gesture engine (swipe, pinch, double-tap, drag-down to
// close, the zoom from and back to the tile). It knows nothing of our data: the
// gallery is `store.total` slides, and the data of each is looked up in the
// store when PhotoSwipe asks for it. A video is a slide whose content this file
// builds.

const INFO_ICON =
  '<svg aria-hidden="true" class="pswp__icn" viewBox="0 0 32 32" width="32" height="32">' +
  '<circle cx="16" cy="16" r="9" fill="none" stroke="#fff" stroke-width="2"/>' +
  '<path d="M16 15v6.5M16 10.8v.4" stroke="#fff" stroke-width="2.4" stroke-linecap="round"/></svg>'

// A photo's title over its lower edge, while the info panel (which shows it) is closed, and
// out of the way of a stack's strip.
const CAPTION_CSS = `
.pk-caption{position:absolute;left:0;right:0;bottom:0;z-index:20;padding:56px 20px calc(18px + env(safe-area-inset-bottom,0px));background:linear-gradient(transparent,#000a);color:#fff;font:600 16px/1.35 system-ui,sans-serif;text-shadow:0 1px 3px #0008;pointer-events:none;transition:opacity .2s}
.pk-caption span{display:-webkit-box;max-width:min(42rem,100%);overflow:hidden;-webkit-line-clamp:2;-webkit-box-orient:vertical}
.pk-caption[hidden],html.pk-info-open .pk-caption{display:none}
.pswp:not(.pswp--ui-visible) .pk-caption{opacity:0}
body:has(.pk-stack-strip:not([hidden])) .pk-caption{padding-bottom:calc(68px + env(safe-area-inset-bottom,0px))}
`

// How much of a video's bottom edge belongs to its native controls, in pixels.
const CONTROLS_STRIP = 72

/** Swipe, pinch, double-tap, drag down to close, and the fly from and back to the tile. */
export class PhotoSwipeEngine {
  static id = "photoswipe"
  static label = "PhotoSwipe"

  constructor(host) {
    this.store = host.store
    this.thumbOf = host.thumbOf
    this.tileImage = host.tileImage
    this.video = host.video
    this.onInfo = host.onInfo
    this.actions = host.actions || []
    this.actionSyncs = []
    this.onChange = host.onChange
    this.onClose = host.onClose
    this.pswp = null
  }

  get isOpen() {
    return this.pswp !== null
  }

  get index() {
    return this.pswp ? this.pswp.currIndex : -1
  }

  open(index) {
    if (this.pswp) return
    addStyle("pk-photoswipe-css", photoswipeCss + SHARED_CSS + CAPTION_CSS)

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
      // The info panel beside (or under) the photo takes its share of the screen, and the
      // photo is laid out in what is left (`info_panel.js`).
      getViewportSizeFn: () => viewportBesidePanel(),
      // Focus may go to the info panel (a title being typed): it is not ours to take back.
      trapFocus: false,
      closeTitle: "Close",
      zoomTitle: "Zoom",
      arrowPrevTitle: "Previous",
      arrowNextTitle: "Next",
      errorMsg: "This could not be loaded"
    })
    this.pswp = pswp

    pswp.addFilter("numItems", () => this.store.total)
    pswp.addFilter("itemData", (_data, i) => this.itemData(i))
    pswp.addFilter("thumbEl", (_el, _data, i) => this.tileImage(i) || undefined)
    pswp.addFilter("placeholderSrc", (_src, content) => content.data.msrc || false)
    pswp.addFilter("useContentPlaceholder", (use, content) => use || content.data.type === "video")

    pswp.on("uiRegister", () => {
      for (const action of this.actions) {
        pswp.ui.registerElement({
          name: action.name,
          order: 7,
          isButton: true,
          appendTo: "bar",
          html: action.icon,
          title: action.label,
          ariaLabel: action.label,
          onClick: () => action.run(pswp.currIndex),
          onInit: (el) => {
            const sync = () => {
              el.style.display = action.shown(pswp.currIndex) ? "" : "none"
            }
            this.actionSyncs.push(sync)
            pswp.on("change", sync)
            sync()
          }
        })
      }
      pswp.ui.registerElement({
        name: "caption",
        appendTo: "root",
        className: "pk-caption",
        html: "<span></span>",
        onInit: (el) => {
          this.captionEl = el
          pswp.on("change", () => this.caption())
          this.caption()
        }
      })
      pswp.ui.registerElement({
        name: "info",
        order: 8,
        isButton: true,
        appendTo: "bar",
        html: INFO_ICON,
        title: "Details",
        ariaLabel: "Details",
        onClick: () => {
          const slide = this.store.get(pswp.currIndex)
          if (slide) this.onInfo(slide.id)
        }
      })
    })

    pswp.on("contentAppend", ({ content }) => this.buildVideo(content))
    pswp.on("contentActivate", ({ content }) => {
      if (pswp.opener.isOpen) this.play(content)
    })
    pswp.on("contentDeactivate", ({ content }) => this.pause(content))
    // The slide the viewer opens on gets its video only once the opening animation is
    // over, and PhotoSwipe builds it in its own `openingAnimationEnd` listener, which runs
    // after this one: so it is started when it is built (`appendHeavyContent`), not here.
    pswp.on("appendHeavyContent", ({ slide }) => {
      if (slide && slide === pswp.currSlide && pswp.opener.isOpen) this.play(slide.content)
    })
    pswp.on("pointerDown", (event) => this.keepControlsUsable(event))
    // The host's own viewer is a dialog over this one: the keys are its, not ours.
    // So are the keys typed into the info panel, or pressed on its buttons.
    pswp.on("keydown", (event) => {
      const target = event.originalEvent && event.originalEvent.target
      if (dialogOpen() || typing(target) || inPanel(target)) event.preventDefault()
    })
    pswp.on("change", () => this.onChange(pswp.currIndex))
    pswp.on("destroy", () => {
      this.pswp = null
      this.captionEl = null
      this.actionSyncs = []
      this.onClose()
    })

    pswp.init()
  }

  close() {
    if (this.pswp) this.pswp.close()
  }

  /** Turn to `index` without the slide animation of a swipe. */
  goTo(index) {
    if (this.pswp) this.pswp.goTo(index)
  }

  /** The title of the photo on screen, or nothing. */
  caption() {
    const el = this.captionEl
    if (!el || !this.pswp) return
    const slide = this.store.get(this.pswp.currIndex)
    const title = slide && slide.title ? String(slide.title) : ""
    el.firstChild.textContent = title
    el.hidden = title === ""
  }

  /** Slides at `indices` have arrived: show them where a waiting slide was. */
  refresh(indices) {
    if (!this.pswp) return
    const here = this.pswp.currIndex
    if (indices.includes(here)) this.caption()
    for (const index of indices) {
      if (Math.abs(index - here) <= 2) this.pswp.refreshSlideContent(index)
    }
  }

  /**
   * The slides beside the current one may be others now (a stack's pages opened in line next
   * to it): draw them again. The current one is left alone, so it does not blink.
   */
  redraw() {
    if (!this.pswp) return
    const here = this.pswp.currIndex
    for (const index of [here - 2, here - 1, here + 1, here + 2]) {
      if (index >= 0 && index < this.store.total) this.pswp.refreshSlideContent(index)
    }
  }

  /** The space it has changed (the info panel opened or closed): lay the photo out again. */
  resize() {
    if (this.pswp) this.pswp.updateSize(true)
  }

  syncActions() {
    for (const sync of this.actionSyncs) sync()
  }

  destroy() {
    if (this.pswp) this.pswp.destroy()
  }

  itemData(index) {
    const slide = this.store.get(index)
    if (!slide) {
      return {
        type: "html",
        html: '<div class="pk-pager__wait" aria-busy="true"></div>',
        width: 1200,
        height: 800
      }
    }

    const msrc = this.thumbOf(slide.id) || slide.poster || undefined
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
      }
    }

    return {
      id: slide.id,
      type: "image",
      src: slide.src || slide.preview || "",
      // Never stretch the grid crop into the full-frame image's dimensions.
      msrc: slide.preview || undefined,
      width: slide.w,
      height: slide.h,
      alt: "",
      thumbCropped: true
    }
  }

  // --- video -----------------------------------------------------------

  buildVideo(content) {
    if (content.data.type !== "video" || content.video || !content.element) return
    content.video = this.video.build(content.data)
    content.element.appendChild(content.video)
  }

  play(content) {
    if (content && content.video) this.video.play(content.video)
  }

  pause(content) {
    if (content && content.video) this.video.pause(content.video)
  }

  // A touch on a video's own control bar is for the controls, not for a swipe.
  keepControlsUsable(event) {
    const target = event.originalEvent && event.originalEvent.target
    if (!target || target.tagName !== "VIDEO") return
    const rect = target.getBoundingClientRect()
    if (event.originalEvent.clientY >= rect.bottom - CONTROLS_STRIP) event.preventDefault()
  }
}
