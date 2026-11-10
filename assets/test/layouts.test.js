import { test } from "node:test"
import assert from "node:assert/strict"
import { STYLE_IDS, STYLES, buildLayout, dayGrid, decodeAspects, parseMonth } from "../js/layouts.js"
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

// The bookmark marks the gap above the first row (or photo) that starts at or below the saved
// place; every style answers that by search, checked here against looking at every tile.
test("edgeBelow is the first tile top at or below a line, in every style", () => {
  for (const style of STYLE_IDS) {
    for (const extra of [{}, { columns: 3, width: 500 }, { count: 7 }]) {
      const layout = buildLayout(style, options(extra))
      const count = options(extra).count
      for (let y = 0; y <= layout.height + 50; y += 37.25) {
        let best = null
        for (let i = 0; i < count; i++) {
          const top = layout.rect(i).y
          if (top >= y - 0.5 && (best === null || top < best)) best = top
        }
        const edge = layout.edgeBelow(y)
        assert(edge === best || Math.abs(edge - best) < 1e-3, `${style} ${JSON.stringify(extra)} at ${y}: ${edge} vs ${best}`)
      }
    }
    assert.equal(buildLayout(style, options({ count: 0 })).edgeBelow(0), null, style)
  }
})

// July 2018 began on a Sunday. Days 14 (20 photos, in two windows the way a big day comes),
// 1 (1 photo) and 31 (3 photos).
const july = (extra = {}) => options({
  count: 24, month: "2018-07", weekStart: 1,
  days: [{ id: "2018-07-01", count: 1 }, { id: "2018-07-14", count: 12 }, { id: "2018-07-14:12", count: 8 },
    { id: "2018-07-31", count: 3 }],
  ...extra
})

test("the calendar puts each day in its weekday's column, Monday first or Sunday first", () => {
  const monday = buildLayout("calendar", july()).calendar
  assert.equal(monday.cells.length, 31)
  // Sunday the 1st is the last column of the first week, Monday the 2nd the first of the next.
  assert.equal(monday.cells[0].x, 6 * (monday.dayW + monday.space))
  assert.equal(monday.cells[1].x, 0)
  assert(monday.cells[1].y > monday.cells[0].y)

  const sunday = buildLayout("calendar", july({ weekStart: 0 })).calendar
  assert.equal(sunday.cells[0].x, 0)
  assert.equal(sunday.cells[0].y, sunday.cells[6].y)
})

test("a month of the calendar is as tall as its weeks", () => {
  // Monday first, July 2018 runs over six weeks; Sunday first, over five.
  const six = buildLayout("calendar", july())
  const five = buildLayout("calendar", july({ weekStart: 0 }))
  const { dayH, space } = six.calendar
  assert(Math.abs(six.height - five.height - (dayH + space)) < 0.01)
  const last = six.calendar.cells[30]
  assert(Math.abs(six.height - (last.y + last.h)) < 0.01)
})

test("a day's photos stay inside its square, and the ones that do not fit have no size", () => {
  for (const cell of [56, 160, 400]) {
    const layout = buildLayout("calendar", july({ cell }))
    let index = 0
    for (const day of layout.calendar.cells) {
      for (let i = index; i < index + day.count; i++) {
        const r = layout.rect(i)
        if (i - index < day.count - day.more) {
          assert(r.w > 0 && r.h > 0, `${cell}: photo ${i}`)
          assert(r.x >= day.x - 0.01 && r.x + r.w <= day.x + day.w + 0.01, `${cell}: photo ${i} x`)
          assert(r.y >= day.y - 0.01 && r.y + r.h <= day.y + day.h + 0.01, `${cell}: photo ${i} y`)
        } else {
          assert.equal(r.w, 0, `${cell}: photo ${i} should be hidden`)
        }
      }
      index += day.count
    }
    assert.equal(index, 24)
  }
})

test("zooming out shows more of a busy day", () => {
  const near = buildLayout("calendar", july({ cell: 400 })).calendar.cells[13]
  const far = buildLayout("calendar", july({ cell: 56 })).calendar.cells[13]
  assert.equal(near.count, 20)
  assert(far.count - far.more > near.count - near.more)
})

test("a day's photos share the square in rows, the first photo the largest", () => {
  assert.deepEqual(dayGrid(1, 100, 100, 3, 3), [1])
  assert.equal(dayGrid(2, 100, 100, 3, 3).reduce((a, b) => a + b), 2)
  assert.deepEqual(dayGrid(3, 100, 100, 3, 3), [1, 2])
  assert.deepEqual(dayGrid(4, 100, 100, 3, 3), [2, 2])
  assert.deepEqual(dayGrid(9, 100, 100, 3, 3), [3, 3, 3])
  assert.equal(dayGrid(5, 100, 100, 3, 3).reduce((a, b) => a + b), 5)
})

test("a section that is not a month is the plain grid in the calendar", () => {
  const layout = buildLayout("calendar", options({ month: "unknown" }))
  assert.equal(layout.calendar, undefined)
  assert.equal(parseMonth("2018-13"), null)
  assert.deepEqual(parseMonth("2018-07"), { year: 2018, month: 7 })
})

test("this month stops at the end of today's week", () => {
  // Monday first, Tuesday 10 July 2018 is in the third week; the photos of the 14th are in it too.
  const early = { count: 21, days: [{ id: "2018-07-01", count: 1 }, { id: "2018-07-14", count: 20 }] }
  const layout = buildLayout("calendar", july({ ...early, today: { year: 2018, month: 7, day: 10 } }))
  const cells = layout.calendar.cells
  assert.equal(cells.length, 15)
  assert.equal(cells[14].future, true)
  assert.equal(cells[9].future, false)
  // The photos of the 31st still have a place: a photo is never dropped for the date.
  const late = buildLayout("calendar", july({ today: { year: 2018, month: 7, day: 3 } })).calendar.cells
  assert.equal(late.length, 31)
  // Another month is whole.
  assert.equal(buildLayout("calendar", july({ today: { year: 2018, month: 8, day: 1 } })).calendar.cells.length, 31)
})
