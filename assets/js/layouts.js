// The styles of the timeline: where each tile of a section goes. Pure math, like geometry.js:
// no DOM and no LiveView, so all of it can be unit tested.
//
// A style is a shape (this file) and a look (timeline_css.js). Every style's section height is
// exact, because the scrollbar, jump to month, the bookmark and the swipe viewer's way back all
// need to know where a photo is before its window has been fetched. Square tiles get that from
// the count alone. The styles that show whole photos get it from the aspect ratio of every file,
// which the server sends as one byte per file (`decodeAspects`), so a library of 200,000 photos
// costs 260 KB once, and nothing has to be measured or corrected while scrolling.

/**
 * Every style, in the order the switcher offers them.
 *
 * `aspects`: the shape depends on the aspect ratio of each photo. `crop`: tiles have a shape of
 * their own, so the square thumbnail will do while they are small. `maxFiles`: the largest
 * library the style can show.
 */
export const STYLES = {
  grid: { aspects: false, crop: true },
  rows: { aspects: true, crop: false },
  columns: { aspects: true, crop: false },
  mosaic: { aspects: true, crop: true },
  whole: { aspects: true, crop: false },
  // A photo a screen tall: past this many, the page is taller than a browser can scroll.
  feed: { aspects: true, crop: false, maxFiles: 30000 },
  prints: { aspects: false, crop: true },
  film: { aspects: false, crop: true },
  honeycomb: { aspects: false, crop: true },
  details: { aspects: false, crop: true }
}

export const STYLE_IDS = Object.keys(STYLES)
export const DEFAULT_STYLE = "grid"

/** How far past the viewport a packed layout keeps tiles, as the grid keeps a row each way. */
const OVERSCAN = 240

/** A row whose top is this close above a line (subpixel scrolling) still counts as below it. */
const EDGE_SLACK = 0.5

// The server's byte: the logarithm of the aspect ratio, from 1:8 to 8:1 in 256 steps of 1.6%.
const ASPECT_LOW = Math.log(1 / 8)
const ASPECT_SPAN = Math.log(8) - ASPECT_LOW
const ASPECT_TABLE = Float32Array.from({ length: 256 }, (_, byte) => Math.exp(ASPECT_LOW + (byte / 255) * ASPECT_SPAN))

/** The aspect ratios of a section, from the base64 of one byte per file. */
export function decodeAspects(base64) {
  const bytes = atob(base64 || "")
  const aspects = new Float32Array(bytes.length)
  for (let i = 0; i < bytes.length; i++) aspects[i] = ASPECT_TABLE[bytes.charCodeAt(i)]
  return aspects
}

/**
 * Tiles in a regular grid: the place of a tile follows from its number, so this holds no
 * arrays and costs nothing for a section of any size.
 */
class Grid {
  constructor({ count, columns, tileW, tileH, gapX, gapY, header, left = 0, stagger = 0 }) {
    Object.assign(this, { count, columns, tileW, tileH, gapX, gapY, header, left, stagger })
    this.rows = count > 0 ? Math.ceil(count / columns) : 0
    this.height = count > 0 ? header + this.rows * tileH + (this.rows - 1) * gapY : header
  }

  rect(index) {
    const row = Math.floor(index / this.columns)
    const col = index % this.columns
    return {
      x: this.left + col * (this.tileW + this.gapX) + (row % 2 ? this.stagger : 0),
      y: this.header + row * (this.tileH + this.gapY),
      w: this.tileW,
      h: this.tileH
    }
  }

  /** The tiles between two heights measured from the top of the section, with a row to spare. */
  range(top, bottom) {
    const stride = this.tileH + this.gapY
    const firstRow = Math.max(0, Math.floor((top - this.header) / stride) - 1)
    const lastRow = Math.ceil((bottom - this.header) / stride) + 1
    const lastIndex = Math.max(0, this.count - 1)
    if (this.count <= 0 || lastRow < 0 || firstRow * this.columns > lastIndex) return { first: 0, last: -1 }
    return {
      first: Math.min(lastIndex, firstRow * this.columns),
      last: Math.min(lastIndex, (lastRow + 1) * this.columns - 1)
    }
  }

  /** A place in the section (px from its top) as a tile number and how far into its row. */
  anchor(delta) {
    const row = Math.max(0, delta - this.header) / (this.tileH + this.gapY)
    // Keep the partial row separately: flooring a fractional tile count on every wake or
    // resize can move the viewport backwards, especially with subpixel cells.
    const wholeRow = Math.floor(row + 1e-9)
    return { item: wholeRow * this.columns, fraction: Math.max(0, row - wholeRow) }
  }

  /** Back again: px below the section's header for a tile number and fraction. */
  contentY(item, fraction = 0) {
    return (Math.floor(item / this.columns) + fraction) * (this.tileH + this.gapY)
  }

  /** The top of the first row that starts at or below `y` (px from the section's top), or null. */
  edgeBelow(y) {
    if (this.count <= 0) return null
    const stride = this.tileH + this.gapY
    const row = Math.max(0, Math.ceil((y - EDGE_SLACK - this.header) / stride))
    return row < this.rows ? this.header + row * stride : null
  }

  /** The tile at a point of the section, or the nearest one. */
  hit(x, y) {
    if (this.count <= 0) return -1
    const row = Math.max(0, Math.floor((y - this.header) / (this.tileH + this.gapY)))
    const shift = this.left + (row % 2 ? this.stagger : 0)
    const col = Math.min(this.columns - 1, Math.max(0, Math.floor((x - shift) / (this.tileW + this.gapX))))
    return Math.min(this.count - 1, row * this.columns + col)
  }
}

/** Tiles placed one by one: four floats a tile, searched by running extremes. */
class Packed {
  constructor(rects, count, height, header, gapY) {
    Object.assign(this, { rects, count, height, header, gapY })
    // Tiles are in photo order, but a column layout can put a later photo above an earlier
    // one. A running maximum of bottoms and a running minimum of tops from the end are
    // sorted however the tiles fall, so both ends of a range can be found by bisection.
    this.bottoms = new Float32Array(count)
    this.tops = new Float32Array(count)
    let bottom = 0
    for (let i = 0; i < count; i++) {
      bottom = Math.max(bottom, rects[i * 4 + 1] + rects[i * 4 + 3])
      this.bottoms[i] = bottom
    }
    let top = Infinity
    for (let i = count - 1; i >= 0; i--) {
      top = Math.min(top, rects[i * 4 + 1])
      this.tops[i] = top
    }
  }

  rect(index) {
    const at = index * 4
    return { x: this.rects[at], y: this.rects[at + 1], w: this.rects[at + 2], h: this.rects[at + 3] }
  }

  /** The first tile whose running bottom reaches `y`. */
  firstAt(y) {
    let lo = 0
    let hi = this.count - 1
    while (lo < hi) {
      const mid = (lo + hi) >> 1
      if (this.bottoms[mid] >= y) hi = mid
      else lo = mid + 1
    }
    return lo
  }

  range(top, bottom) {
    if (this.count <= 0) return { first: 0, last: -1 }
    if (this.bottoms[this.count - 1] < top - OVERSCAN) return { first: 0, last: -1 }
    const first = this.firstAt(top - OVERSCAN)
    const end = bottom + OVERSCAN
    let lo = first
    let hi = this.count - 1
    while (lo < hi) {
      const mid = (lo + hi + 1) >> 1
      if (this.tops[mid] <= end) lo = mid
      else hi = mid - 1
    }
    return this.tops[first] > end ? { first: 0, last: -1 } : { first, last: lo }
  }

  anchor(delta) {
    if (this.count <= 0) return { item: 0, fraction: 0 }
    const item = this.firstAt(delta)
    const { y, h } = this.rect(item)
    return { item, fraction: Math.min(1, Math.max(0, (delta - y) / (h + this.gapY))) }
  }

  contentY(item, fraction = 0) {
    if (this.count <= 0) return 0
    const { y, h } = this.rect(Math.min(item, this.count - 1))
    return y - this.header + fraction * (h + this.gapY)
  }

  /**
   * The top of the first tile that starts at or below `y`, or null. Tiles before `firstAt(y)` end
   * above `y`; past it, the running minimum of tops says when nothing later can start sooner.
   */
  edgeBelow(y) {
    if (this.count <= 0 || this.bottoms[this.count - 1] < y - EDGE_SLACK) return null
    let best = Infinity
    for (let i = this.firstAt(y - EDGE_SLACK); i < this.count && this.tops[i] < best; i++) {
      const top = this.rects[i * 4 + 1]
      if (top >= y - EDGE_SLACK && top < best) best = top
    }
    return best === Infinity ? null : best
  }

  hit(x, y) {
    if (this.count <= 0) return -1
    const { first, last } = this.range(y, y)
    let nearest = -1
    let best = Infinity
    for (let i = first; i <= last; i++) {
      const r = this.rect(i)
      const dx = Math.max(r.x - x, 0, x - r.x - r.w)
      const dy = Math.max(r.y - y, 0, y - r.y - r.h)
      const distance = dx * dx + dy * dy
      if (distance < best) {
        best = distance
        nearest = i
      }
    }
    return nearest < 0 ? Math.min(this.count - 1, first) : nearest
  }
}

/** Squares, cropped to fill. The one style that needs nothing but the count. */
function grid({ count, columns, cell, gap, header }) {
  return new Grid({ count, columns, tileW: cell, tileH: cell, gapX: gap, gapY: gap, header })
}

/** Rows of the same height across the width, every photo whole. */
function rows({ count, aspectAt, width, cell, gap, header }) {
  const rects = new Float32Array(count * 4)
  const target = Math.max(cell, 48)
  let y = header
  let start = 0

  while (start < count) {
    let sum = 0
    let end = start
    // Add photos while that brings the row nearer the height aimed for.
    while (end < count) {
      const next = sum + aspectAt(end)
      const gaps = (end - start) * gap
      const height = (width - gaps) / next
      if (end > start && Math.abs(height - target) > Math.abs((width - (gaps - gap)) / sum - target)) break
      sum = next
      end++
      if (height <= target) break
    }

    const gaps = (end - start - 1) * gap
    // The last row of a section is not stretched to the width.
    const last = end >= count
    const height = last ? Math.min((width - gaps) / sum, target) : (width - gaps) / sum
    let x = 0
    for (let i = start; i < end; i++) {
      const w = aspectAt(i) * height
      rects.set([x, y, w, height], i * 4)
      x += w + gap
    }
    y += height + gap
    start = end
  }

  return new Packed(rects, count, count > 0 ? y - gap : header, header, gap)
}

/** Columns of the same width, each photo going under the shortest one. */
function columns({ count, aspectAt, columns: columnCount, cell, gap, header }) {
  const rects = new Float32Array(count * 4)
  const bottoms = new Float32Array(columnCount).fill(header)

  for (let i = 0; i < count; i++) {
    let column = 0
    for (let c = 1; c < columnCount; c++) if (bottoms[c] < bottoms[column] - 0.5) column = c
    // A panorama would be a sliver and a tall strip a wall: hold them to a sensible shape.
    const height = cell / Math.min(2.4, Math.max(0.42, aspectAt(i)))
    rects.set([column * (cell + gap), bottoms[column], cell, height], i * 4)
    bottoms[column] += height + gap
  }

  const bottom = count > 0 ? Math.max(...bottoms) - gap : header
  return new Packed(rects, count, bottom, header, gap)
}

// The same photo always gets the same dice, so a mosaic does not reshuffle on the next visit.
function dice(index) {
  let value = (index + 1) * 2654435761
  value = (value ^ (value >>> 15)) >>> 0
  return value % 100
}

/** How many cells a photo spans in a mosaic: wide ones go wide, tall ones tall, some go big. */
function span(aspect, roll, columnCount) {
  if (columnCount < 2) return [1, 1]
  if (roll < 11) return [2, 2]
  if (aspect >= 1.45 && roll < 46) return [2, 1]
  if (aspect <= 0.8 && roll < 46) return [1, 2]
  return [1, 1]
}

/** A dense pack of squares and doubles, in photo order as far as the holes allow. */
function mosaic({ count, aspectAt, columns: columnCount, cell, gap, header }) {
  const rects = new Float32Array(count * 4)
  const taken = []
  const stride = cell + gap
  const free = (row, col, w, h) => {
    if (col + w > columnCount) return false
    for (let r = row; r < row + h; r++) {
      for (let c = col; c < col + w; c++) if (taken[r]?.[c]) return false
    }
    return true
  }
  let firstOpen = 0
  let lastRow = -1

  for (let i = 0; i < count; i++) {
    const [w, h] = span(aspectAt(i), dice(i), columnCount)
    let row = firstOpen
    let col = 0
    while (!free(row, col, w, h)) {
      col++
      if (col >= columnCount) {
        col = 0
        row++
      }
    }
    for (let r = row; r < row + h; r++) {
      taken[r] = taken[r] || new Uint8Array(columnCount)
      for (let c = col; c < col + w; c++) taken[r][c] = 1
    }
    while (taken[firstOpen]?.every(Boolean)) firstOpen++
    lastRow = Math.max(lastRow, row + h - 1)
    rects.set([col * stride, header + row * stride, w * cell + (w - 1) * gap, h * cell + (h - 1) * gap], i * 4)
  }

  const height = count > 0 ? header + (lastRow + 1) * stride - gap : header
  return new Packed(rects, count, height, header, gap)
}

/** The square grid with each photo whole inside its square, on a shared baseline. */
function whole({ count, aspectAt, columns: columnCount, cell, gap, header }) {
  const rects = new Float32Array(count * 4)
  const pad = cell * 0.06
  const inner = cell - pad * 2
  const stride = cell + gap

  for (let i = 0; i < count; i++) {
    const aspect = aspectAt(i)
    const w = aspect >= 1 ? inner : inner * aspect
    const h = aspect >= 1 ? inner / aspect : inner
    const row = Math.floor(i / columnCount)
    const col = i % columnCount
    rects.set([col * stride + (cell - w) / 2, header + row * stride + (cell - h) / 2, w, h], i * 4)
  }

  const rowCount = Math.ceil(count / columnCount)
  return new Packed(rects, count, count > 0 ? header + rowCount * stride - gap : header, header, gap)
}

/** One photo after another down the middle of the page, as large as the zoom says. */
function feed({ count, aspectAt, width, cell, gap, header }) {
  const rects = new Float32Array(count * 4)
  const column = Math.min(width, Math.max(280, cell * 3.4))
  const space = Math.max(gap, 18)
  let y = header

  for (let i = 0; i < count; i++) {
    const aspect = Math.max(0.6, aspectAt(i))
    const h = column / aspect
    rects.set([(width - column) / 2, y, column, h], i * 4)
    y += h + space
  }

  return new Packed(rects, count, count > 0 ? y - space : header, header, space)
}

/** Paper prints on a table: room around each, and a white edge that is taller at the foot. */
function prints({ count, columns: columnCount, width, cell, header }) {
  const gap = Math.max(10, cell * 0.11)
  const tile = columnCount > 1 ? (width - (columnCount - 1) * gap) / columnCount : width
  return new Grid({ count, columns: columnCount, tileW: tile, tileH: tile * 1.18, gapX: gap, gapY: gap, header })
}

/** Strips of 35 mm film: frames edge to edge in a row, a little space between the strips. */
function film({ count, columns: columnCount, width, cell, gap, header }) {
  const tile = width / columnCount
  return new Grid({
    count, columns: columnCount, tileW: tile, tileH: Math.max(cell * 0.2, tile * 0.86),
    gapX: 0, gapY: Math.max(gap, 10), header
  })
}

/** Circles packed like cells of a comb: every other row sits half a tile over. */
function honeycomb({ count, columns: columnCount, width, gap, header }) {
  const space = Math.max(gap, 4)
  const tile = (width - (columnCount - 0.5) * space) / (columnCount + 0.5)
  return new Grid({
    count, columns: columnCount, tileW: tile, tileH: tile, gapX: space,
    gapY: space - tile * 0.13, header, stagger: (tile + space) / 2
  })
}

/** A list with what is known of each file; wide screens get more than one column of it. */
function details({ count, width, gap, header }) {
  const space = Math.max(gap, 2)
  const columnCount = Math.max(1, Math.floor((width + 16) / 380))
  const tile = (width - (columnCount - 1) * 16) / columnCount
  return new Grid({ count, columns: columnCount, tileW: tile, tileH: 72, gapX: 16, gapY: space, header })
}

const BUILDERS = { grid, rows, columns, mosaic, whole, feed, prints, film, honeycomb, details }

/**
 * The layout of one section. `aspectAt(i)` gives the aspect ratio of its file `i`, `width` is the
 * width to fill, `columns` and `cell` come from the zoom (`cell` is the height of a row in `rows`).
 */
export function buildLayout(style, options) {
  return (BUILDERS[style] || grid)(options)
}
