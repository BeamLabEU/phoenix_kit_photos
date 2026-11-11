// The swipe viewer's list with stacks opened in line, over the timeline's own list
// (`SlideStore`, slides.js), with no DOM so it can be tested.
//
// The timeline counts a stack once: its cover has one position, like any photo, and its
// slide says `stack: { id, count, title }`. The viewer shows a stack's photos one after
// another where the stack is ("pages in line"), so its list is the timeline's with each
// stack whose pages have arrived (`expand`) opened up: a stack of 8 at timeline position
// 40 is viewer positions 40 to 47, and timeline position 41 is viewer position 48.
//
// A stack is open in the list only while its cover is still where the timeline has it
// (`store.indexOf(cover)` and that slide names the stack): after the timeline's index
// changes under the viewer, a stack that moved opens again where it went, one that went
// away does not.
//
// Engines read `total` and `get(i)` (viewer positions); the timeline converts with
// `toView` and `fromView`.

export class StackedList {
  constructor(store) {
    this.store = store
    // stack id -> { cover: id of the slide that stands for it, pages: [slide, ...] }
    this.stacks = new Map()
    this.asked = new Set()
  }

  /** The stacks open in the list, by their timeline position: `[{ id, at, pages }]`. */
  open() {
    if (this.stacks.size === 0 || !this.store) return []
    const found = []
    for (const [id, { cover, pages }] of this.stacks) {
      if (pages.length < 2) continue
      const at = this.store.indexOf(cover)
      if (at < 0) continue
      const slide = this.store.get(at)
      if (!slide || !slide.stack || slide.stack.id !== id) continue
      found.push({ id, at, pages })
    }
    return found.sort((a, b) => a.at - b.at)
  }

  get total() {
    if (!this.store) return 0
    let extra = 0
    for (const stack of this.open()) extra += stack.pages.length - 1
    return this.store.total + extra
  }

  /** The viewer position of timeline position `at`, on page `page` of a stack there. */
  toView(at, page = 0) {
    let view = at
    for (const stack of this.open()) {
      if (stack.at < at) view += stack.pages.length - 1
      else if (stack.at === at) return view + Math.max(0, Math.min(page, stack.pages.length - 1))
      else break
    }
    return view
  }

  /**
   * Where viewer position `index` is: `{ at, page, stack }`, `at` the timeline position, and
   * for a page of an open stack its `page` and the stack (`{ id, at, pages }`), else page 0 and
   * no stack.
   */
  fromView(index) {
    let shift = 0
    for (const stack of this.open()) {
      const first = stack.at + shift
      if (index < first) break
      const last = first + stack.pages.length - 1
      if (index <= last) return { at: stack.at, page: index - first, stack }
      shift += stack.pages.length - 1
    }
    return { at: index - shift, page: 0, stack: null }
  }

  has(index) {
    return this.get(index) !== null
  }

  get(index) {
    if (index < 0) return null
    const { at, page, stack } = this.fromView(index)
    if (stack) return stack.pages[page] || null
    return this.store && this.store.get ? this.store.get(at) : null
  }

  /** The viewer position of the photo `id`, a stack's page or not; -1 when not known. */
  indexOf(id) {
    for (const stack of this.open()) {
      const page = stack.pages.findIndex((slide) => slide.id === id)
      if (page >= 0) return this.toView(stack.at, page)
    }
    const at = this.store && this.store.indexOf ? this.store.indexOf(id) : -1
    return at >= 0 ? this.toView(at, 0) : -1
  }

  /**
   * A stack's pages arrived (`pages`, its photos in order, the first being its cover). The
   * stack opens in the list when `cover` is still its slide in the timeline.
   */
  expand(id, cover, pages) {
    this.asked.delete(id)
    if (!Array.isArray(pages) || pages.length === 0) {
      this.stacks.delete(id)
      return
    }
    this.stacks.set(id, { cover, pages })
  }

  /**
   * The stacks among the timeline's slides from `from` to `to` (timeline positions) whose
   * pages are neither here nor asked for: `[{ id, cover }]`. Marks them asked.
   */
  wanted(from, to) {
    const out = []
    if (!this.store || !this.store.get) return []
    for (let at = Math.max(0, from); at <= to; at++) {
      const slide = this.store.get(at)
      const stack = slide && slide.stack
      if (!stack || !(stack.count >= 2)) continue
      const known = this.stacks.get(stack.id)
      if (this.asked.has(stack.id) || (known && known.cover === slide.id && known.pages.length === stack.count)) {
        continue
      }
      this.asked.add(stack.id)
      out.push({ id: stack.id, cover: slide.id })
    }
    return out
  }

  /** An answer that never came: the stack may be asked for again. */
  forget(id) {
    this.asked.delete(id)
  }

  /**
   * What the strip says about viewer position `index`: `null` off a stack, else
   * `{ id, title, page, count, first, last }`, `first` and `last` being the viewer positions
   * of its first and last page.
   */
  pageInfo(index) {
    const { at, page, stack } = this.fromView(index)
    if (!stack) return null
    const cover = this.store.get(at)
    const first = this.toView(at, 0)
    return {
      id: stack.id,
      title: (cover && cover.stack && cover.stack.title) || null,
      page,
      count: stack.pages.length,
      first,
      last: first + stack.pages.length - 1,
      pages: stack.pages
    }
  }
}
