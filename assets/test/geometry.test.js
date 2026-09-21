import { test } from "node:test"
import assert from "node:assert/strict"

import {
  squareSectionHeight,
  buildOffsets,
  totalHeight,
  sectionAtOffset,
  visibleSections,
  anchorAt,
  offsetForAnchor
} from "../js/geometry.js"

const M = { columns: 5, cell: 100, gap: 10, header: 40 }
const h = (count) => squareSectionHeight({ count, ...M })

test("square height is exact, not estimated", () => {
  assert.equal(h(0), 40)
  assert.equal(h(1), 140)
  assert.equal(h(5), 140)
  assert.equal(h(6), 250)
  assert.equal(h(10), 250)
})

test("offsets are prefix sums with a trailing total", () => {
  const sections = [{ count: 5 }, { count: 6 }, { count: 1 }]
  const offsets = buildOffsets(sections, (s) => h(s.count))
  assert.deepEqual(offsets, [0, 140, 390, 530])
  assert.equal(totalHeight(offsets), 530)
})

test("binary search finds the section containing an offset", () => {
  const offsets = [0, 140, 390, 530]
  assert.equal(sectionAtOffset(offsets, 0), 0)
  assert.equal(sectionAtOffset(offsets, 139), 0)
  assert.equal(sectionAtOffset(offsets, 140), 1)
  assert.equal(sectionAtOffset(offsets, 389), 1)
  assert.equal(sectionAtOffset(offsets, 390), 2)
})

test("offsets out of range clamp instead of throwing", () => {
  const offsets = [0, 140, 390, 530]
  assert.equal(sectionAtOffset(offsets, -50), 0)
  assert.equal(sectionAtOffset(offsets, 99999), 2)
  assert.equal(sectionAtOffset([0], 10), -1)
})

test("a jump lands exactly on a section start", () => {
  const sections = [{ count: 5 }, { count: 6 }, { count: 1 }]
  const offsets = buildOffsets(sections, (s) => h(s.count))
  for (let i = 0; i < sections.length; i++) {
    assert.equal(sectionAtOffset(offsets, offsets[i]), i)
  }
})

test("visible sections include the buffer and stay in range", () => {
  const offsets = [0, 140, 390, 530]
  assert.deepEqual(visibleSections(offsets, 0, 100, 0), [0])
  assert.deepEqual(visibleSections(offsets, 0, 100, 1), [0, 1])
  assert.deepEqual(visibleSections(offsets, 400, 100, 5), [0, 1, 2])
})

test("anchor restores position after every height changes", () => {
  const sections = [{ count: 5 }, { count: 6 }, { count: 1 }]
  const before = buildOffsets(sections, (s) => h(s.count))
  const scrollTop = 200
  const anchor = anchorAt(before, scrollTop)
  assert.deepEqual(anchor, { index: 1, delta: 60 })

  // Wider container: three columns become four, so every section shrinks.
  const wide = (count) => squareSectionHeight({ count, ...M, columns: 10 })
  const after = buildOffsets(sections, (s) => wide(s.count))
  assert.equal(offsetForAnchor(after, anchor), after[1] + 60)
})
