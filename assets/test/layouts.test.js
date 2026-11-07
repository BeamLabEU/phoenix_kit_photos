import { test } from "node:test"
import assert from "node:assert/strict"
import { STYLE_IDS, STYLES, buildLayout, decodeAspects } from "../js/layouts.js"
import { squareSectionHeight } from "../js/geometry.js"
import { pickSource } from "../js/tiles.js"

const shapes = [1.5, 0.66, 1, 1.33, 3.6, 0.56, 1.5]
const options = (extra = {}) => ({
  count: 200, aspectAt: i => shapes[i % shapes.length],
  columns: 5, width: 816, cell: 160, gap: 4, header: 40, ...extra
})

test("the plain grid has the height geometry.js has always given it", () => {
  for (const count of [0, 1, 5, 6, 501]) {
    const layout = buildLayout("grid", options({ count }))
    assert.equal(layout.height, squareSectionHeight({ count, columns: 5, cell: 160, gap: 4, header: 40 }))
  }
})

test("an empty section is only its header, in every style", () => {
  for (const style of STYLE_IDS) {
    const layout = buildLayout(style, options({ count: 0 }))
    assert.equal(layout.height, 40, style)
    assert.deepEqual(layout.range(0, 1000), { first: 0, last: -1 }, style)
    assert.equal(layout.hit(10, 10), -1, style)
  }
})

test("every tile of every style has a place on the page, inside the section", () => {
  for (const style of STYLE_IDS) {
    const layout = buildLayout(style, options())
    for (let i = 0; i < 200; i++) {
      const r = layout.rect(i)
      assert(r.w > 0 && r.h > 0, `${style} ${i}`)
      assert(r.x >= -0.01 && r.x + r.w <= 816.01, `${style} ${i}: ${JSON.stringify(r)}`)
      assert(r.y >= 40 && r.y + r.h <= layout.height + 0.01, `${style} ${i}: ${JSON.stringify(r)}`)
    }
  }
})

test("a range holds every tile that crosses it", () => {
  for (const style of STYLE_IDS) {
    const layout = buildLayout(style, options())
    for (const [top, bottom] of [[0, 500], [900, 1400], [layout.height - 300, layout.height]]) {
      const { first, last } = layout.range(top, bottom)
      for (let i = 0; i < 200; i++) {
        const r = layout.rect(i)
        if (r.y < bottom && r.y + r.h > top) assert(i >= first && i <= last, `${style}: tile ${i} missing from ${first}-${last}`)
      }
    }
  }
})

test("a range past the section holds nothing", () => {
  for (const style of STYLE_IDS) {
    const layout = buildLayout(style, options())
    assert.deepEqual(layout.range(layout.height + 2000, layout.height + 2500), { first: 0, last: -1 }, style)
  }
})

test("a place in a section survives being turned into a tile and back", () => {
  for (const style of STYLE_IDS) {
    const layout = buildLayout(style, options())
    for (const delta of [40, 333, 1200.5]) {
      const { item, fraction } = layout.anchor(delta)
      const back = 40 + layout.contentY(item, fraction)
      assert(Math.abs(back - delta) < layout.rect(item).h + 8, `${style} ${delta} -> ${back}`)
      assert(fraction >= 0 && fraction <= 1, style)
    }
  }
})

test("a point on a tile finds that tile", () => {
  for (const style of STYLE_IDS) {
    const layout = buildLayout(style, options())
    for (const i of [0, 7, 77, 199]) {
      const r = layout.rect(i)
      const found = layout.hit(r.x + r.w / 2, r.y + r.h / 2)
      const other = layout.rect(found)
      assert(r.x + r.w / 2 >= other.x - 0.01 && r.x + r.w / 2 <= other.x + other.w + 0.01, `${style}: ${i} found ${found}`)
    }
  }
})

test("a row of whole photos fills the width, every photo keeping its shape", () => {
  const layout = buildLayout("rows", options())
  const byRow = new Map()
  for (let i = 0; i < 200; i++) {
    const r = layout.rect(i)
    assert(Math.abs(r.w / r.h - shapes[i % shapes.length]) < 1e-3, `tile ${i}`)
    byRow.set(r.y, [...(byRow.get(r.y) || []), r])
  }
  const rows = [...byRow.values()]
  for (const row of rows.slice(0, -1)) {
    const end = row[row.length - 1]
    assert(Math.abs(end.x + end.w - 816) < 0.5, "a full row ends at the edge")
  }
  const end = rows[rows.length - 1].at(-1)
  assert(end.x + end.w <= 816.5, "the last row is not stretched past the page")
  assert(rows[rows.length - 1][0].h <= 160.01, "and not higher than a row is meant to be")
})

test("a mosaic is the same every time, and no two tiles share a cell", () => {
  const a = buildLayout("mosaic", options())
  const b = buildLayout("mosaic", options())
  assert.deepEqual(a.rect(150), b.rect(150))
  const cells = new Set()
  for (let i = 0; i < 200; i++) {
    const r = a.rect(i)
    for (let y = r.y + 1; y < r.y + r.h; y += 164) {
      for (let x = r.x + 1; x < r.x + r.w; x += 164) {
        const cell = `${Math.floor(x / 164)}:${Math.floor((y - 40) / 164)}`
        assert(!cells.has(cell), `cell ${cell} taken twice`)
        cells.add(cell)
      }
    }
  }
})

test("one column still lays out in every style", () => {
  for (const style of STYLE_IDS) {
    const layout = buildLayout(style, options({ columns: 1, width: 300, cell: 300 }))
    assert(layout.height > 40, style)
    assert(layout.rect(199).x + layout.rect(199).w <= 300.01, style)
  }
})

test("the server's byte reads back as the aspect ratio within its step", () => {
  const encode = ar => Math.round((Math.log(ar) + Math.log(8)) * 255 / (2 * Math.log(8)))
  const ratios = [0.125, 0.5625, 1, 1.5, 8]
  const decoded = decodeAspects(btoa(String.fromCharCode(...ratios.map(encode))))
  assert.equal(decoded.length, ratios.length)
  ratios.forEach((ratio, i) => assert(Math.abs(decoded[i] / ratio - 1) < 0.02, `${ratio} read as ${decoded[i]}`))
  assert.equal(decodeAspects("").length, 0)
})

test("a tile asks for the lightest picture sharp enough for its shape and the screen", () => {
  const item = { thumb: "t", fit: "f", preview: "p", large: "l" }
  assert.equal(pickSource(item, 170, 170, STYLES.grid, 2), "t", "small square")
  assert.equal(pickSource(item, 400, 400, STYLES.grid, 2), "p", "a big square needs a big picture")
  assert.equal(pickSource(item, 170, 110, STYLES.rows, 1), "f", "small and not square")
  assert.equal(pickSource(item, 300, 200, STYLES.rows, 2), "p", "retina")
  assert.equal(pickSource(item, 680, 450, STYLES.feed, 2), "l", "filling the page")
  assert.equal(pickSource({ thumb: "t" }, 680, 450, STYLES.feed, 2), "t", "whatever there is")
  assert.equal(pickSource({ preview: "p" }, 170, 170, STYLES.grid, 1), "p", "no thumbnail yet")
})
