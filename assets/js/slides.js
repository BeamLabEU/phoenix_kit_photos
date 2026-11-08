// The swipe viewer's data, with no DOM and no PhotoSwipe, so it can be tested.
//
// The timeline index lists every month and, inside it, every day (or 500-item
// slice of a day) with its count. Laying those end to end gives each file a
// global position, 0 .. total - 1, in the order the grid shows them. The viewer
// is a PhotoSwipe gallery of `total` slides; a slide's data is fetched in blocks
// of BLOCK files around the one on screen and kept here.

export const BLOCK = 12

/** The days of every section laid end to end: `{ id, count, start }`. */
export function flattenDays(sections) {
  const days = []
  let start = 0
  for (const section of sections || []) {
    for (const day of section.days_list || []) {
      const count = day.count || 0
      if (count <= 0) continue
      days.push({ id: day.id, count, start })
      start += count
    }
  }
  return { days, total: start }
}

/** The day holding global position `index`, and the position inside it. */
export function locate(days, index) {
  let low = 0
  let high = days.length - 1
  while (low <= high) {
    const mid = (low + high) >> 1
    const day = days[mid]
    if (index < day.start) high = mid - 1
    else if (index >= day.start + day.count) low = mid + 1
    else return { day, position: index - day.start }
  }
  return null
}

/**
 * The blocks to fetch so every position within `radius` of `center` is known:
 * `{ key, window, from, count, start }`, `start` being the first global position
 * the block is for.
 */
export function blocksAround(days, total, center, radius) {
  const blocks = new Map()
  const first = Math.max(0, center - radius)
  const last = Math.min(total - 1, center + radius)
  for (let index = first; index <= last; index++) {
    const found = locate(days, index)
    if (!found) continue
    const from = found.position - (found.position % BLOCK)
    const key = `${found.day.id}@${from}`
    if (!blocks.has(key)) {
      blocks.set(key, {
        key,
        window: found.day.id,
        from,
        count: BLOCK,
        start: found.day.start + from
      })
    }
  }
  return [...blocks.values()]
}

/** What the viewer knows: the slides fetched so far, and the blocks asked for. */
export class SlideStore {
  constructor(sections) {
    const { days, total } = flattenDays(sections)
    this.days = days
    this.total = total
    this.slides = new Map()
    this.asked = new Set()
    this.byId = new Map()
  }

  has(index) {
    return this.slides.has(index)
  }

  get(index) {
    return this.slides.get(index) || null
  }

  indexOf(id) {
    return this.byId.has(id) ? this.byId.get(id) : -1
  }

  /** Blocks around `center` that are neither here nor already asked for. */
  missing(center, radius) {
    return blocksAround(this.days, this.total, center, radius).filter(
      (block) => !this.asked.has(block.key) && !this.knowsBlock(block)
    )
  }

  knowsBlock(block) {
    const last = Math.min(block.start + block.count - 1, this.total - 1)
    for (let index = block.start; index <= last; index++) {
      if (!this.slides.has(index)) return false
    }
    return true
  }

  markAsked(block) {
    this.asked.add(block.key)
  }

  /** Forget that a block was asked for (the answer was an error), so it can be asked again. */
  forget(window, from) {
    this.asked.delete(`${window}@${from}`)
  }

  /**
   * Files `items`, which started at `from` in the day `window`; the indices whose slide is new
   * (not known before, or another file than was kept there over a `rebase`).
   */
  put(window, from, items) {
    const day = this.days.find((d) => d.id === window)
    if (!day) return []
    const added = []
    items.forEach((item, offset) => {
      const index = day.start + from + offset
      if (index >= this.total) return
      const before = this.slides.get(index)
      if (!before || before.id !== item.id) added.push(index)
      if (before && before.id !== item.id && this.byId.get(before.id) === index) this.byId.delete(before.id)
      this.slides.set(index, item)
      this.byId.set(item.id, index)
    })
    return added
  }

  /**
   * The index changed under an open viewer (an upload, say). A day with the same id and count
   * keeps its slides, moved to where the day starts now; a day that changed is fetched again,
   * and nothing asked before counts. `keep` (`{ index, slide }`, the slide on screen) stays at
   * its new place even when its day changed, so the viewer does not blink while that day is
   * fetched; whether it is still there is for the answer to tell.
   *
   * Returns where the old position `keep.index` is now: its day moved as a whole, or, in a
   * changed day, the same place in it. -1 when its day is gone.
   */
  rebase(sections, keep = null) {
    const { days, total } = flattenDays(sections)
    const now = new Map(days.map((day) => [day.id, day]))
    const same = (day) => {
      const next = now.get(day.id)
      return next && next.count === day.count ? next : null
    }

    const slides = new Map()
    const byId = new Map()
    for (const [index, slide] of this.slides) {
      const found = locate(this.days, index)
      const next = found && same(found.day)
      if (!next) continue
      slides.set(next.start + found.position, slide)
      byId.set(slide.id, next.start + found.position)
    }

    let at = -1
    if (keep) {
      const found = locate(this.days, keep.index)
      const next = found && now.get(found.day.id)
      if (next) at = next.start + Math.min(found.position, next.count - 1)
      if (at >= 0 && keep.slide && !slides.has(at)) {
        slides.set(at, keep.slide)
        byId.set(keep.slide.id, at)
      }
    }

    this.days = days
    this.total = total
    this.slides = slides
    this.byId = byId
    this.asked = new Set()
    return at
  }
}

/** The width, in device pixels, to ask full-size pictures for. */
export function wantWidth(view) {
  const ratio = view.devicePixelRatio || 1
  return Math.max(400, Math.min(4096, Math.round(view.innerWidth * ratio)))
}

/**
 * Which file to play, of the sources the server lists (renditions first, the
 * original last).
 *
 * The renditions are SDR H.264. The original keeps HDR, so on a screen that shows
 * HDR, and a browser that can play it, the original is preferred; everywhere else
 * the first rendition is, and the original only when there is none.
 */
export function chooseSource(sources, env) {
  const list = sources || []
  const original = list.find((s) => s.role === "original")
  const rendition = list.find((s) => s.role === "rendition")

  if (original && env.hdrScreen && env.canPlay(original.type)) return original
  return rendition || original || null
}
