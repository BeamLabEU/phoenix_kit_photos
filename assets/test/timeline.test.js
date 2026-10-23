import { test } from "node:test"
import assert from "node:assert/strict"
import { PhotoTimeline } from "../js/photo_timeline.js"
function hook() {
  const sent = []
  return { sent, h: Object.assign({}, PhotoTimeline, {
    el: { dataset: { target: "7" }, scrollTop: 0, clientHeight: 500 },
    columns: 5, metrics: { cell: 160, gap: 4, header: 40 },
    sections: [], offsets: [0], windows: new Map(), pool: new Map(),
    library: null, revision: null, needed: new Set(),
    pushEventTo: (...args) => sent.push(args), materialize() {},
  }) }
}
const section = (count = 501) => ({ id: "2020-01", count,
  days_list: [{ id: "2020-01-01", count: Math.min(count, 500) },
    ...(count > 500 ? [{ id: "2020-01-01:500", count: count - 500 }] : [])] })
test("window requests target the component and include large-day tails", () => {
  const { h, sent } = hook()
  h.setIndex({ library: "a", revision: 1, sections: [section()] })
  assert(sent.some(([target, event, payload]) => target === 7 && event === "timeline:need_window" && payload.window === "2020-01-01:500" && payload.revision === 1))
})
test("same-library refresh invalidates cached windows and rejects stale responses", () => {
  const { h } = hook()
  h.setIndex({ library: "a", revision: 1, sections: [section(1)] })
  h.setWindow({ section: "2020-01-01", revision: 1, items: [{ id: "old" }] })
  h.setIndex({ library: "a", revision: 2, sections: [section(1)] })
  assert.equal(h.windows.get("2020-01-01"), null)
  h.setWindow({ section: "2020-01-01", revision: 1, items: [{ id: "stale" }] })
  assert.equal(h.windows.get("2020-01-01"), null)
  h.setWindow({ section: "2020-01-01", revision: 2, items: [{ id: "new" }] })
  assert.equal(h.windows.get("2020-01-01")[0].id, "new")
})
test("switching libraries cannot reuse previous windows", () => {
  const { h } = hook()
  h.setIndex({ library: "a", revision: 1, sections: [section(1)] })
  h.setWindow({ section: "2020-01-01", revision: 1, items: [{ id: "a" }] })
  h.setIndex({ library: "b", revision: 2, sections: [section(1)] })
  h.setWindow({ section: "2020-01-01", revision: 1, items: [{ id: "a" }] })
  assert.equal(h.windows.get("2020-01-01"), null)
})
test("scrolling evicts windows away from the viewport", () => {
  const { h } = hook()
  const sections = Array.from({ length: 120 }, (_, i) => ({ id: String(i), count: 500, days_list: [{ id: `day-${i}`, count: 500 }] }))
  h.setIndex({ library: "a", revision: 1, sections })
  for (const section of sections) { h.jumpTo(section.id); assert(h.windows.size <= 3) }
})
test("offscreen sections do not materialize arbitrary tail tiles", () => {
  const { h } = hook()
  h.sections = [section(1)]; h.offsets = [0, 200]; h.el.scrollTop = 2000
  assert.deepEqual(h.visibleItemRange(h.sections[0]), { first: 0, last: -1 })
})

test("resizing preserves the same row and all columns fit the container", () => {
  const { h } = hook()
  h.el.clientWidth = 816
  h.setIndex({ library: "a", revision: 1, sections: [section()] })
  h.el.scrollTop = 40 + 20 * 164
  h.el.clientWidth = 375
  h.handleResize()
  assert.equal(h.metrics.cell * 5 + h.metrics.gap * 4, 375)
  assert.equal((h.el.scrollTop - 40) / (h.metrics.cell + h.metrics.gap), 20)
})

test("the pager setting on the component picks the engine (or none)", () => {
  const { h } = hook()
  const on = setting => { h.el.closest = () => ({ dataset: { pager: setting } }); return h.pagerEngine() }
  assert.equal(on("false"), null)
  assert.equal(on("true"), "photoswipe")
  assert.equal(on("snap"), "snap")
  assert.equal(on("nope"), "photoswipe")
  assert.equal(h.pagerEnabled(), true)
  assert.equal(on("false") === null && h.pagerEnabled(), false)
  h.el.closest = () => null
  assert.equal(h.pagerEngine(), null)
})


test("a header the grid scrolls under: the first row rests below it, a jump lands under it", () => {
  const { h } = hook()
  h.readInset = () => 56
  h.el.clientWidth = 816
  h.setIndex({ library: "a", revision: 1, sections: [section(10), { ...section(10), id: "2020-02" }] })
  assert.equal(h.offsets[0], 56)
  h.jumpTo("2020-02")
  assert.equal(h.el.scrollTop + 56, h.offsets[1])
  // a resize at the very top stays at the very top
  h.jumpTo("2020-01")
  h.el.clientWidth = 400
  h.handleResize()
  assert.equal(h.el.scrollTop, 0)
})

test("with a target tile size the columns follow the width and the same tile stays on screen", () => {
  const { h } = hook()
  h.targetCell = 160
  h.el.clientWidth = 1324
  h.setIndex({ library: "a", revision: 1, sections: [section(300)] })
  assert.equal(h.columns, 8)
  assert.equal(h.metrics.cell * 8 + h.metrics.gap * 7, 1324)
  const tileAtTop = () => Math.floor((h.el.scrollTop - 40) / (h.metrics.cell + h.metrics.gap)) * h.columns
  h.el.scrollTop = 40 + 10 * (h.metrics.cell + h.metrics.gap)
  const before = tileAtTop()
  h.el.clientWidth = 400
  h.handleResize()
  assert.equal(h.columns, 3)
  // the same tile, to the row: it may sit anywhere in its new, shorter row
  assert(tileAtTop() <= before && before - tileAtTop() < h.columns)
})

test("the pill shows the month at the top of the screen", () => {
  const { h } = hook()
  h.current = { textContent: "" }
  h.el.clientWidth = 816
  h.setIndex({ library: "a", revision: 1, sections: [{ ...section(10), label: "January 2020" }, { ...section(10), id: "2020-02", label: "February 2020" }] })
  assert.equal(h.current.textContent, "January 2020")
  h.jumpTo("2020-02")
  assert.equal(h.current.textContent, "February 2020")
})
