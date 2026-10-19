import { dialogOpen } from "./engine.js"
import { SHARED_CSS, addStyle } from "./video.js"

// The scroll-snap engine (see engine.js for the contract): the browser's own
// scrolling does the swiping, which is what a phone's pages feel like, and three
// pages (previous, current, next) are all there is in the DOM. It is deliberately
// basic: no pinch or double-tap zoom, no flight to and from the tile (a fade), no
// drag down to close. It is the baseline to compare an engine with, and proof that
// the contract does not belong to one library.

const CSS = `
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
`

const INFO_ICON =
  '<svg aria-hidden="true" viewBox="0 0 32 32" width="32" height="32"><circle cx="16" cy="16" r="9" fill="none" stroke="#fff" stroke-width="2"/>' +
  '<path d="M16 15v6.5M16 10.8v.4" stroke="#fff" stroke-width="2.4" stroke-linecap="round"/></svg>'
const CLOSE_ICON =
  '<svg aria-hidden="true" viewBox="0 0 32 32" width="32" height="32"><path d="M9 9l14 14M23 9L9 23" stroke="#fff" stroke-width="2.4" stroke-linecap="round"/></svg>'

const SETTLE_MS = 100
const FADE_MS = 180

export class SnapEngine {
  static id = "snap"
  static label = "Scroll-snap (basic)"

  constructor(host) {
    this.host = host
    this.store = host.store
    this.video = host.video
    this.root = null
    this.track = null
    this.pages = []
    this.current = -1
    this.settleTimer = null
    this.closing = false
  }

  get isOpen() {
    return this.root !== null
  }

  get index() {
    return this.current
  }

  open(index) {
    if (this.root) return
    addStyle("pk-snap-css", CSS + SHARED_CSS)

    const root = document.createElement("div")
    root.className = "pk-snap"
    root.setAttribute("role", "dialog")
    root.setAttribute("aria-modal", "true")
    root.innerHTML =
      '<div class="pk-snap__bar"><span class="pk-snap__count"></span>' +
      `<button type="button" class="pk-snap__button pk-snap__info" aria-label="Details">${INFO_ICON}</button>` +
      `<button type="button" class="pk-snap__button pk-snap__close" aria-label="Close">${CLOSE_ICON}</button></div>` +
      '<div class="pk-snap__track"></div>'

    this.root = root
    this.track = root.querySelector(".pk-snap__track")
    this.count = root.querySelector(".pk-snap__count")
    this.current = index

    for (let i = 0; i < 3; i++) {
      const page = document.createElement("div")
      page.className = "pk-snap__page"
      this.track.appendChild(page)
    }
    this.pages = [...this.track.children]

    root.querySelector(".pk-snap__close").addEventListener("click", () => this.close())
    root.querySelector(".pk-snap__info").addEventListener("click", () => {
      const slide = this.store.get(this.current)
      if (slide) this.host.onInfo(slide.id)
    })
    this.track.addEventListener("scroll", () => this.onScroll(), { passive: true })
    // Where the browser says when the scrolling has stopped, take its word (the timer
    // is the fallback for those that do not).
    this.track.addEventListener("scrollend", () => {
      clearTimeout(this.settleTimer)
      this.settle()
    })
    this.onKey = (event) => this.keydown(event)
    this.onResize = () => this.center()
    document.addEventListener("keydown", this.onKey, true)
    window.addEventListener("resize", this.onResize)

    this.previousOverflow = document.documentElement.style.overflow
    document.documentElement.style.overflow = "hidden"
    document.body.appendChild(root)

    this.fill()
    this.center()
    this.showCount()
    requestAnimationFrame(() => {
      root.setAttribute("data-open", "")
      this.activate()
    })
  }

  close() {
    if (!this.root || this.closing) return
    this.closing = true
    this.pauseAll()
    this.root.removeAttribute("data-open")
    setTimeout(() => this.destroy(), FADE_MS)
  }

  destroy() {
    if (!this.root) return
    clearTimeout(this.settleTimer)
    document.removeEventListener("keydown", this.onKey, true)
    window.removeEventListener("resize", this.onResize)
    document.documentElement.style.overflow = this.previousOverflow || ""
    this.pauseAll()
    this.root.remove()
    this.root = this.track = null
    this.pages = []
    this.closing = false
    this.host.onClose()
  }

  /** Slides at `indices` have arrived: draw them where a waiting page was. */
  refresh(indices) {
    if (!this.root) return
    for (const index of indices) {
      const offset = index - this.current
      if (offset < -1 || offset > 1) continue
      const page = this.pages[offset + 1]
      if (page.dataset.state === "wait") this.draw(page, index)
    }
  }

  // --- pages -----------------------------------------------------------

  fill() {
    this.pages.forEach((page, i) => this.draw(page, this.current + i - 1))
  }

  draw(page, index) {
    this.pauseIn(page)
    page.replaceChildren()
    delete page.video

    if (index < 0 || index >= this.store.total) {
      page.dataset.state = "empty"
      return
    }

    const slide = this.store.get(index)
    if (!slide) {
      page.dataset.state = "wait"
      const wait = document.createElement("div")
      wait.className = "pk-pager__wait"
      wait.setAttribute("aria-busy", "true")
      page.appendChild(wait)
      return
    }

    page.dataset.state = "ready"
    if (slide.kind === "video") {
      page.video = this.video.build(slide)
      page.appendChild(page.video)
    } else {
      const img = document.createElement("img")
      img.alt = ""
      img.draggable = false
      img.src = slide.src || this.host.thumbOf(slide.id) || ""
      page.appendChild(img)
    }
  }

  center() {
    if (this.track) this.track.scrollLeft = this.track.clientWidth
  }

  showCount() {
    this.count.textContent = `${this.current + 1} / ${this.store.total}`
  }

  // --- paging ----------------------------------------------------------

  onScroll() {
    clearTimeout(this.settleTimer)
    this.settleTimer = setTimeout(() => this.settle(), SETTLE_MS)
  }

  // The scrolling stopped on a page: if it is not the middle one, the page turned.
  settle() {
    if (!this.track) return
    const width = this.track.clientWidth
    if (width === 0) return
    const page = Math.round(this.track.scrollLeft / width)
    if (page === 1) return

    const target = this.current + (page - 1)
    if (target < 0 || target >= this.store.total) {
      this.track.scrollTo({ left: width, behavior: "smooth" })
      return
    }
    this.turn(page === 2 ? 1 : -1)
  }

  turn(direction) {
    this.pauseIn(this.pages[1])
    this.current += direction

    // Move the page that left the other end and draw the new neighbour into it,
    // so the pages that stay (and a video playing in one) are not rebuilt.
    if (direction > 0) {
      const gone = this.pages.shift()
      this.track.appendChild(gone)
      this.pages.push(gone)
      this.draw(gone, this.current + 1)
    } else {
      const gone = this.pages.pop()
      this.track.insertBefore(gone, this.track.firstChild)
      this.pages.unshift(gone)
      this.draw(gone, this.current - 1)
    }

    this.center()
    this.showCount()
    this.activate()
    this.host.onChange(this.current)
  }

  activate() {
    const page = this.pages[1]
    if (page && page.video) this.video.play(page.video)
  }

  pauseIn(page) {
    if (page && page.video) this.video.pause(page.video)
  }

  pauseAll() {
    this.pages.forEach((page) => this.pauseIn(page))
  }

  keydown(event) {
    // The host's own viewer is a dialog over this one: the keys are its, not ours.
    if (dialogOpen()) return
    if (event.key === "Escape") {
      event.preventDefault()
      event.stopPropagation()
      this.close()
    } else if (event.key === "ArrowRight" || event.key === "ArrowLeft") {
      event.preventDefault()
      const width = this.track.clientWidth
      this.track.scrollTo({ left: event.key === "ArrowRight" ? width * 2 : 0, behavior: "smooth" })
    }
  }
}
