import PhotoSwipe from "photoswipe"
import photoswipeCss from "photoswipe/dist/photoswipe.css"
import { dialogOpen } from "./engine.js"
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
    addStyle("pk-photoswipe-css", photoswipeCss + SHARED_CSS)

    const pswp = new PhotoSwipe({
      dataSource: [],
      index,
      loop: false,
      bgOpacity: 1,
      preload: [1, 2],
      showHideAnimationType: "zoom",
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
    })
    this.pswp = pswp

    pswp.addFilter("numItems", () => this.store.total)
    pswp.addFilter("itemData", (_data, i) => this.itemData(i))
    pswp.addFilter("thumbEl", (_el, _data, i) => this.tileImage(i) || undefined)
    pswp.addFilter("useContentPlaceholder", (use, content) => use || content.data.type === "video")

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
    pswp.on("openingAnimationEnd", () => {
      if (pswp.currSlide) this.play(pswp.currSlide.content)
    })
    pswp.on("pointerDown", (event) => this.keepControlsUsable(event))
    // The host's own viewer is a dialog over this one: the keys are its, not ours.
    pswp.on("keydown", (event) => {
      if (dialogOpen()) event.preventDefault()
    })
    pswp.on("change", () => this.onChange(pswp.currIndex))
    pswp.on("destroy", () => {
      this.pswp = null
      this.onClose()
    })

    pswp.init()
  }

  close() {
    if (this.pswp) this.pswp.close()
  }

  /** Slides at `indices` have arrived: show them where a waiting slide was. */
  refresh(indices) {
    if (!this.pswp) return
    const here = this.pswp.currIndex
    for (const index of indices) {
      if (Math.abs(index - here) <= 2) this.pswp.refreshSlideContent(index)
    }
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
      src: slide.src || msrc || "",
      msrc,
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
