// What the swipe viewer shows over a stack's photo: the stack's title, "3 of 8", a dot (or a
// small picture, past a dozen pages) for each page that turns to it, Skip, and for someone
// who may change the stack, Edit. It sits above whichever engine turns the pages, since it is
// about the timeline's data, not about gestures.
//
// The hook gives it what to show (`update(info)`, `StackedList.pageInfo`) and what to do
// (`onGo(viewIndex)`, `onSkip(direction)`, `onEdit(info)`); `strings` are translated
// (`data-stack-strings` on the timeline's root).

const MAX_DOTS = 12

const CSS = `
.pk-stack-strip{position:fixed;left:50%;bottom:calc(14px + env(safe-area-inset-bottom,0px));transform:translateX(-50%);z-index:2147483000;display:flex;align-items:center;gap:10px;max-width:calc(100vw - 24px);padding:6px 8px 6px 14px;border-radius:999px;background:#000b;color:#fff;font:500 13px/1.2 system-ui,sans-serif;box-shadow:0 6px 24px -8px #000;backdrop-filter:blur(8px);-webkit-backdrop-filter:blur(8px)}
.pk-stack-strip[hidden]{display:none}
.pk-stack-strip__title{max-width:28vw;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;font-weight:600}
.pk-stack-strip__count{white-space:nowrap;font-variant-numeric:tabular-nums;opacity:.8}
.pk-stack-strip__pages{display:flex;align-items:center;gap:4px;overflow-x:auto;max-width:46vw;scrollbar-width:none}
.pk-stack-strip__pages::-webkit-scrollbar{display:none}
.pk-stack-strip__dot{flex:none;width:9px;height:9px;padding:0;border:0;border-radius:50%;background:#fff6;cursor:pointer}
.pk-stack-strip__dot[aria-current="true"]{background:#fff;transform:scale(1.25)}
.pk-stack-strip__thumb{flex:none;width:30px;height:30px;padding:0;border:2px solid transparent;border-radius:5px;background:#fff2 center/cover no-repeat;cursor:pointer;opacity:.7}
.pk-stack-strip__thumb[aria-current="true"]{border-color:#fff;opacity:1}
.pk-stack-strip__button{flex:none;padding:5px 11px;border:0;border-radius:999px;background:#fff2;color:inherit;font:inherit;cursor:pointer}
.pk-stack-strip__button:hover{background:#fff4}
.pk-stack-strip__button:focus-visible,.pk-stack-strip__dot:focus-visible,.pk-stack-strip__thumb:focus-visible{outline:2px solid #fff;outline-offset:2px}
@media (max-width:520px){.pk-stack-strip__title{display:none}.pk-stack-strip__pages{max-width:38vw}}
`

function addStyle() {
  if (document.getElementById("pk-stack-strip-css")) return
  const style = document.createElement("style")
  style.id = "pk-stack-strip-css"
  style.textContent = CSS
  document.head.appendChild(style)
}

const fill = (text, values) =>
  Object.entries(values).reduce((out, [key, value]) => out.replaceAll(`%{${key}}`, String(value)), text)

export class StackStrip {
  constructor({ strings = {}, editable = false, onGo, onSkip, onEdit }) {
    this.strings = { of: "%{page} of %{count}", skip: "Skip", edit: "Edit stack", page: "Page %{page}", ...strings }
    this.editable = editable
    this.onGo = onGo
    this.onSkip = onSkip
    this.onEdit = onEdit
    this.el = null
    this.info = null
  }

  build() {
    addStyle()
    const el = document.createElement("div")
    el.className = "pk-stack-strip"
    el.hidden = true
    el.setAttribute("role", "group")

    this.title = document.createElement("span")
    this.title.className = "pk-stack-strip__title"
    this.count = document.createElement("span")
    this.count.className = "pk-stack-strip__count"
    this.count.setAttribute("aria-live", "polite")
    this.pages = document.createElement("div")
    this.pages.className = "pk-stack-strip__pages"

    this.skip = document.createElement("button")
    this.skip.type = "button"
    this.skip.className = "pk-stack-strip__button"
    this.skip.textContent = `${this.strings.skip} ⇥`
    this.skip.addEventListener("click", () => this.onSkip(1))

    el.append(this.title, this.count, this.pages, this.skip)

    if (this.editable) {
      this.edit = document.createElement("button")
      this.edit.type = "button"
      this.edit.className = "pk-stack-strip__button"
      this.edit.textContent = this.strings.edit
      this.edit.addEventListener("click", () => this.info && this.onEdit(this.info))
      el.append(this.edit)
    }

    // A tap on the strip is for the strip, not for the viewer under it (which would take it as
    // the start of a swipe, or a tap to close).
    for (const type of ["pointerdown", "click", "touchstart"]) {
      el.addEventListener(type, (event) => event.stopPropagation())
    }

    document.body.appendChild(el)
    this.el = el
  }

  /** Show `info` (`StackedList.pageInfo`), or hide for `null`. */
  update(info) {
    if (!info) return this.hide()
    if (!this.el) this.build()

    const same = this.info && this.info.id === info.id && this.info.count === info.count && this.info.first === info.first
    this.info = info
    this.title.textContent = info.title || ""
    this.title.hidden = !info.title
    this.el.setAttribute("aria-label", info.title || fill(this.strings.of, { page: info.page + 1, count: info.count }))
    this.count.textContent = fill(this.strings.of, { page: info.page + 1, count: info.count })

    if (!same) this.drawPages(info)
    this.pages.querySelectorAll("button").forEach((button, i) => {
      button.setAttribute("aria-current", String(i === info.page))
    })
    const current = this.pages.children[info.page]
    if (current && current.scrollIntoView) current.scrollIntoView({ block: "nearest", inline: "nearest" })
    this.el.hidden = false
  }

  drawPages(info) {
    const thumbs = info.count > MAX_DOTS
    this.pages.replaceChildren()
    info.pages.forEach((slide, i) => {
      const button = document.createElement("button")
      button.type = "button"
      button.className = thumbs ? "pk-stack-strip__thumb" : "pk-stack-strip__dot"
      button.setAttribute("aria-label", fill(this.strings.page, { page: i + 1 }))
      if (thumbs && slide.thumb) button.style.backgroundImage = `url("${slide.thumb}")`
      button.addEventListener("click", () => this.onGo(info.first + i))
      this.pages.appendChild(button)
    })
  }

  hide() {
    if (this.el) this.el.hidden = true
    this.info = null
  }

  destroy() {
    if (this.el) this.el.remove()
    this.el = null
    this.info = null
  }
}

/**
 * The hook of the viewer's Edit stack dialog: a modal `<dialog>`, so it is above the viewer and
 * the keys are its own while it is open (`dialogOpen()` in viewer/engine.js). Closing it with
 * Escape tells the component.
 */
export const PhotoStackDialog = {
  mounted() {
    this.onCancel = (event) => {
      event.preventDefault()
      this.pushEventTo(this.el, "timeline:stack_edit_close", {})
    }
    this.el.addEventListener("cancel", this.onCancel)
    if (typeof this.el.showModal === "function" && !this.el.open) this.el.showModal()
  },

  destroyed() {
    this.el.removeEventListener("cancel", this.onCancel)
  }
}
