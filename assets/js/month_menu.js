// The "⋯" after a month's heading ("June 2026 ⋯") and the little menu it opens: for now one
// action, Copy link to this month. The heading lives in the timeline's layer (photo_timeline.js
// places it); the menu lives in <body>, fixed under the button, so the scroller never clips it.
//
//   const button = monthMoreButton(label)        // appended to a heading by the hook
//   const menu = new MonthMenu()
//   menu.open(button, [{ label, run }])          // closes on a pick, Escape, a click outside,
//   menu.close(); menu.destroy()                 // a resize, or its button leaving the screen
//
// A scroll moves it with its button (the timeline settles its scroll after a click, too).

/** The heading's "⋯" button; `label` is its accessible name ("More for June 2026"). */
export function monthMoreButton(label) {
  const button = document.createElement("button")
  button.type = "button"
  button.className = "pkt-month-more"
  button.dataset.monthMore = ""
  button.setAttribute("aria-haspopup", "menu")
  button.setAttribute("aria-expanded", "false")
  button.setAttribute("aria-label", label)
  button.title = label
  button.textContent = "⋯"
  return button
}

/** "More for %{month}" with the month's name in it. */
export function moreLabel(template, month) {
  return (template || "More for %{month}").replace("%{month}", month)
}

export class MonthMenu {
  constructor() {
    this.node = null
    this.button = null
    this.onKey = (event) => this.key(event)
    this.onOutside = (event) => {
      if (this.node && !this.node.contains(event.target) && event.target !== this.button) this.close()
    }
    this.onAway = () => this.close()
    this.onScroll = () => this.place()
  }

  get isOpen() {
    return Boolean(this.node)
  }

  open(button, items) {
    const same = this.button === button
    this.close()
    // A second click on the same "⋯" closes it.
    if (same) return

    const node = document.createElement("div")
    node.className = "pkt-month-menu"
    node.setAttribute("role", "menu")
    for (const item of items) {
      const entry = document.createElement("button")
      entry.type = "button"
      entry.setAttribute("role", "menuitem")
      entry.className = "pkt-month-menu-item"
      if (item.icon) {
        const icon = document.createElement("span")
        icon.className = `${item.icon} pkt-month-menu-icon`
        icon.setAttribute("aria-hidden", "true")
        entry.append(icon)
      }
      entry.append(document.createTextNode(item.label))
      entry.addEventListener("click", () => {
        this.close()
        item.run()
      })
      node.append(entry)
    }
    document.body.append(node)

    this.node = node
    this.button = button
    this.place()
    button.setAttribute("aria-expanded", "true")
    document.addEventListener("keydown", this.onKey, true)
    document.addEventListener("pointerdown", this.onOutside, true)
    window.addEventListener("resize", this.onAway)
    window.addEventListener("scroll", this.onScroll, true)
    node.querySelector("[role=menuitem]")?.focus({ preventScroll: true })
  }

  /** Under its button; gone with it. */
  place() {
    if (!this.node) return
    const at = this.button.getBoundingClientRect()
    if (!this.button.isConnected || at.bottom < 0 || at.top > window.innerHeight) return this.close()
    const width = this.node.offsetWidth
    this.node.style.left = `${Math.max(8, Math.min(at.left, window.innerWidth - width - 8))}px`
    this.node.style.top = `${at.bottom + 4}px`
  }

  key(event) {
    if (!this.node) return
    const items = [...this.node.querySelectorAll("[role=menuitem]")]
    const at = items.indexOf(document.activeElement)
    if (event.key === "Escape") {
      event.preventDefault()
      event.stopPropagation()
      const button = this.button
      this.close()
      button?.focus({ preventScroll: true })
    } else if (event.key === "ArrowDown" || event.key === "ArrowUp") {
      event.preventDefault()
      const step = event.key === "ArrowDown" ? 1 : -1
      items[(at + step + items.length) % items.length]?.focus()
    } else if (event.key === "Tab") {
      this.close()
    }
  }

  close() {
    if (!this.node) return
    this.node.remove()
    this.node = null
    this.button?.setAttribute("aria-expanded", "false")
    this.button = null
    document.removeEventListener("keydown", this.onKey, true)
    document.removeEventListener("pointerdown", this.onOutside, true)
    window.removeEventListener("resize", this.onAway)
    window.removeEventListener("scroll", this.onScroll, true)
  }

  destroy() {
    this.close()
  }
}
