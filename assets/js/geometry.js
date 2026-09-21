// Pure layout math for the timeline. No DOM, no LiveView, no PhoenixKit —
// this is the piece that stays portable, and the piece worth unit testing.

/**
 * Exact height of a square-grid section.
 *
 * Square heights are exact, which is why the Stage 1 contract test does not
 * need tombstones or height refinement. Justified heights are estimates and
 * only become exact after layout, which is what makes Stage 2 a prerequisite
 * for Stage 3 rather than for Stage 1.
 */
export function squareSectionHeight({ count, columns, cell, gap, header }) {
  if (count <= 0) return header
  const rows = Math.ceil(count / columns)
  return header + rows * cell + (rows - 1) * gap
}

/**
 * Prefix sums of section heights.
 *
 * Returns `offsets` with one entry per section plus a trailing total, so
 * `offsets[i]` is where section `i` starts and `offsets[n]` is the full
 * scrollHeight of the library. That total is the whole point: the scrollbar
 * cannot be a map of time until the client knows the height of history it has
 * not fetched.
 */
export function buildOffsets(sections, measure) {
  const offsets = new Array(sections.length + 1)
  let acc = 0
  for (let i = 0; i < sections.length; i++) {
    offsets[i] = acc
    acc += measure(sections[i], i)
  }
  offsets[sections.length] = acc
  return offsets
}

/** Total height, i.e. the last prefix sum. */
export function totalHeight(offsets) {
  return offsets.length ? offsets[offsets.length - 1] : 0
}

/**
 * Index of the section containing `y`, by binary search over prefix sums.
 *
 * This is jump-to-date: map a date to its section index, read `offsets[i]`,
 * and scrollTo. Clamps rather than throwing, because scroll positions
 * legitimately overshoot during momentum scrolling.
 */
export function sectionAtOffset(offsets, y) {
  const last = offsets.length - 2
  if (last < 0) return -1
  if (y <= 0) return 0
  if (y >= offsets[last + 1]) return last

  let lo = 0
  let hi = last
  while (lo < hi) {
    const mid = (lo + hi + 1) >> 1
    if (offsets[mid] <= y) lo = mid
    else hi = mid - 1
  }
  return lo
}

/**
 * Section indices intersecting a viewport, plus a buffer of whole sections
 * on each side. These are the sections to materialize; everything else stays
 * a placeholder of known height.
 */
export function visibleSections(offsets, scrollTop, viewportHeight, buffer = 1) {
  const last = offsets.length - 2
  if (last < 0) return []
  const first = sectionAtOffset(offsets, scrollTop)
  const lastVisible = sectionAtOffset(offsets, scrollTop + viewportHeight)
  const from = Math.max(0, first - buffer)
  const to = Math.min(last, lastVisible + buffer)
  const out = []
  for (let i = from; i <= to; i++) out.push(i)
  return out
}

/**
 * An anchor for restoring position across a relayout.
 *
 * On resize every section above the viewport changes height too, so a
 * scrollTop delta is not enough — the anchor has to be an item, re-resolved
 * against the new offsets.
 */
export function anchorAt(offsets, scrollTop) {
  const index = sectionAtOffset(offsets, scrollTop)
  if (index < 0) return null
  return { index, delta: scrollTop - offsets[index] }
}

/** Scroll position that puts `anchor` back where it was. */
export function offsetForAnchor(offsets, anchor) {
  if (!anchor || anchor.index < 0 || anchor.index >= offsets.length - 1) return 0
  return offsets[anchor.index] + anchor.delta
}
