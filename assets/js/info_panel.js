// The swipe viewer's info panel (`PhoenixKitPhotos.Components.InfoPanel`) from the browser's
// side: opening and closing it, making room for it, and telling the server which photo it is
// about. The panel itself is the server's (title, date, place, comments); this file only
// places it.
//
// It is a `popover="manual"` element, so it sits in the browser's top layer above the viewer
// (which is a fixed element of its own) without being a modal: the photo beside it still
// swipes, and the panel follows it. On a wide screen it is a column at the right and the viewer
// gets narrower; on a narrow one it is a sheet over the lower part and the viewer gets shorter.
// Either way the photo stays whole, beside or above it. The engine is told its new size
// (`resize()`).
//
// Whether it is open is remembered in the browser (`phoenix_kit_photos:info`), so a person who
// reads the details keeps seeing them on the next photo and the next visit.

const KEY = "phoenix_kit_photos:info"
const WIDE = "(min-width: 768px)"
const PANEL_WIDTH = 380

const CSS = `
.pk-info-panel{position:fixed;inset:auto;margin:0;max-width:none;max-height:none;box-sizing:border-box;transition:transform .28s cubic-bezier(.4,0,.22,1)}
.pk-info-panel:popover-open{display:block}
@media ${WIDE}{.pk-info-panel{top:0;right:0;bottom:0;left:auto;width:${PANEL_WIDTH}px;height:100dvh;border-left:1px solid #fff1}}
@media not all and ${WIDE}{.pk-info-panel{left:0;right:0;bottom:0;top:auto;width:100%;height:var(--pk-info-sheet,58dvh);border-radius:18px 18px 0 0;padding-bottom:env(safe-area-inset-bottom,0px)}}
.pk-info-grip{display:none}
@media not all and ${WIDE}{.pk-info-grip{display:block;position:absolute;left:50%;top:5px;width:36px;height:4px;margin-left:-18px;border-radius:2px;background:currentColor;opacity:.25}}
html.pk-info-open .pswp{width:calc(100% - var(--pk-info-right,0px))!important;height:calc(100% - var(--pk-info-bottom,0px))!important}
.pk-info-saved{animation:pk-info-saved 2.2s ease forwards}
@keyframes pk-info-saved{0%,70%{opacity:1}100%{opacity:0}}
.pk-info-comments h3{font-size:.875rem}
`

function addStyle() {
  if (document.getElementById("pk-info-panel-css")) return
  const style = document.createElement("style")
  style.id = "pk-info-panel-css"
  style.textContent = CSS
  document.head.appendChild(style)
}

function remembered() {
  try {
    return window.localStorage.getItem(KEY) === "open"
  } catch (_error) {
    return false
  }
}

function remember(open) {
  try {
    window.localStorage.setItem(KEY, open ? "open" : "closed")
  } catch (_error) {
    // Private mode: it is only a convenience.
  }
}

/** True while focus is in a field the person types into: the keys are theirs then. */
export function typing(target = document.activeElement) {
  if (!target || target === document.body) return false
  const tag = target.tagName
  if (tag === "INPUT") return !NOT_TYPED.has((target.type || "text").toLowerCase())
  return tag === "TEXTAREA" || tag === "SELECT" || target.isContentEditable === true
}

// Inputs a person does not type into: the arrow keys over them are the viewer's.
const NOT_TYPED = new Set(["checkbox", "radio", "button", "submit", "reset", "range", "file", "color", "image"])

/**
 * True when `target` is inside the info panel (a click or a key there is not the viewer's).
 * By the panel's own class: the timeline's root carries `data-info-panel` too (the panel's
 * id), so looking for that attribute took every tile for part of the panel, and a tile
 * focused by the click that opened the viewer kept Escape and the arrows from it.
 */
export function inPanel(target) {
  return !!(target && target.closest && target.closest(".pk-info-panel"))
}

export class InfoPanelController {
  /**
   * `host.element()` the panel's element (re-read, LiveView may have replaced it),
   * `host.show(id)` asks the server for photo `id`, `host.resize()` tells the engine its
   * viewport changed, `host.current()` the id of the photo on screen.
   */
  constructor(host) {
    this.host = host
    this.isOpen = false
    this.shownId = null
    this.timer = null
    this.wide = window.matchMedia ? window.matchMedia(WIDE) : { matches: true }
    this.onMedia = () => this.layout()
    if (this.wide.addEventListener) this.wide.addEventListener("change", this.onMedia)
    addStyle()
  }

  /** The viewer opened: open the panel too if the person left it open. */
  viewerOpened(id) {
    if (remembered()) this.open(id, { remember: false })
  }

  toggle(id) {
    if (this.isOpen) this.close()
    else this.open(id)
  }

  open(id, { remember: keep = true } = {}) {
    const el = this.host.element()
    if (!el || typeof el.showPopover !== "function") return false
    if (keep) remember(true)
    if (!this.isOpen) {
      this.show(el)
      this.isOpen = true
      document.documentElement.classList.add("pk-info-open")
      this.watch()
      this.layout()
    }
    this.follow(id, true)
    return true
  }

  show(el) {
    try {
      if (el && el.isConnected && !el.matches(":popover-open")) el.showPopover()
    } catch (_error) {
      // Not in the document yet: the watch below shows it when it is.
    }
  }

  // LiveView may move the part of the page the panel is in (a patch of the address when the
  // viewer turns a page), and a popover taken out of the document closes without a word. While
  // it should be open, any change to the page checks it still is.
  watch() {
    if (this.observer || typeof MutationObserver === "undefined") return
    this.observer = new MutationObserver(() => {
      if (this.isOpen) this.show(this.host.element())
    })
    this.observer.observe(document.body, { childList: true, subtree: true })
  }

  unwatch() {
    if (this.observer) this.observer.disconnect()
    this.observer = null
  }

  /** `remember: false` when the viewer closes: the panel comes back with it next time. */
  close({ remember: keep = true } = {}) {
    if (!this.isOpen) return
    if (keep) remember(false)
    this.isOpen = false
    this.shownId = null
    this.unwatch()
    clearTimeout(this.timer)
    const el = this.host.element()
    try {
      if (el && el.matches(":popover-open")) el.hidePopover()
    } catch (_error) {
      // Gone already.
    }
    document.documentElement.classList.remove("pk-info-open")
    this.setRoom(0, 0)
  }

  /** The viewer turned to photo `id`: the panel follows, after the swiping settles. */
  follow(id, now = false) {
    if (!this.isOpen || !id || id === this.shownId) return
    clearTimeout(this.timer)
    const go = () => {
      this.shownId = id
      this.host.show(id)
    }
    if (now) go()
    else this.timer = setTimeout(go, 140)
  }

  /** How much of the screen the panel takes, given to the viewer. */
  room() {
    if (!this.isOpen) return { right: 0, bottom: 0 }
    if (this.wide.matches) return { right: PANEL_WIDTH, bottom: 0 }
    const el = this.host.element()
    const height = el ? el.getBoundingClientRect().height : 0
    return { right: 0, bottom: Math.round(height || window.innerHeight * 0.58) }
  }

  layout() {
    if (!this.isOpen) return
    const { right, bottom } = this.room()
    this.setRoom(right, bottom)
  }

  setRoom(right, bottom) {
    const style = document.documentElement.style
    style.setProperty("--pk-info-right", `${right}px`)
    style.setProperty("--pk-info-bottom", `${bottom}px`)
    this.host.resize()
  }

  destroy() {
    this.close({ remember: false })
    if (this.wide.removeEventListener) this.wide.removeEventListener("change", this.onMedia)
  }
}

/** The viewport an engine should lay its photo out in: the window less the panel. */
export function viewportBesidePanel() {
  const style = getComputedStyle(document.documentElement)
  const open = document.documentElement.classList.contains("pk-info-open")
  const right = open ? parseFloat(style.getPropertyValue("--pk-info-right")) || 0 : 0
  const bottom = open ? parseFloat(style.getPropertyValue("--pk-info-bottom")) || 0 : 0
  return {
    x: Math.max(120, document.documentElement.clientWidth - right),
    y: Math.max(120, window.innerHeight - bottom)
  }
}
