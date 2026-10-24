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
    known: new Set(), fresh: new Set(), refreshing: new Set(),
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
test("a same-library refresh keeps the tiles on screen, asks for them again, and rejects stale answers", () => {
  const { h, sent } = hook()
  h.setIndex({ library: "a", revision: 1, sections: [section(1)] })
  h.setWindow({ section: "2020-01-01", revision: 1, items: [{ id: "old" }] })
  sent.length = 0
  h.setIndex({ library: "a", revision: 2, sections: [section(2)] })
  assert.equal(h.windows.get("2020-01-01")[0].id, "old", "the old tiles stay until the answer comes")
  assert(sent.some(([, event, payload]) => event === "timeline:need_window" && payload.window === "2020-01-01" && payload.revision === 2))
  assert.equal(sent.filter(([, event, payload]) => event === "timeline:need_window" && payload.window === "2020-01-01").length, 1, "asked once, not twice")
  h.setWindow({ section: "2020-01-01", revision: 1, items: [{ id: "stale" }] })
  assert.equal(h.windows.get("2020-01-01")[0].id, "old")
  h.setWindow({ section: "2020-01-01", revision: 2, items: [{ id: "old" }, { id: "new" }] })
  assert.deepEqual(h.windows.get("2020-01-01").map(i => i.id), ["old", "new"])
  assert.deepEqual([...h.fresh], ["new"], "only the photo never seen before is new")
})

test("a request still in flight when the index changes is asked for again", () => {
  const { h, sent } = hook()
  h.setIndex({ library: "a", revision: 1, sections: [section(1)] })
  assert.equal(h.windows.get("2020-01-01"), null)
  sent.length = 0
  h.setIndex({ library: "a", revision: 2, sections: [section(1)] })
  assert(sent.some(([, event, payload]) => event === "timeline:need_window" && payload.revision === 2))
})

test("while the viewer is open the refresh waits, then catches up when it closes", () => {
  const { h } = hook()
  h.setIndex({ library: "a", revision: 1, sections: [section(1)] })
  h.pager = { destroy() { throw new Error("the viewer must stay open") } }
  h.setIndex({ library: "a", revision: 2, sections: [section(2)] })
  assert.equal(h.revision, 1)
  h.pager = null
  h.applyDeferred()
  assert.equal(h.revision, 2)
  assert.equal(h.sections[0].count, 2)
})

test("at the end of the library a refresh follows the new photos; elsewhere it stays put", () => {
  const { h } = hook()
  h.el.clientWidth = 816
  const months = (n) => Array.from({ length: n }, (_, i) => ({ ...section(40), id: `2020-0${i + 1}` }))
  h.setIndex({ library: "a", revision: 1, sections: months(3) })
  const end = () => h.offsets[h.offsets.length - 1] - h.el.clientHeight
  assert.equal(h.el.scrollTop, end())
  h.setIndex({ library: "a", revision: 2, sections: months(4) })
  assert.equal(h.el.scrollTop, end(), "followed the growth")
  h.el.scrollTop = 100
  h.setIndex({ library: "a", revision: 3, sections: months(5) })
  assert(Math.abs(h.el.scrollTop - 100) < 200, "did not jump to the end")
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

// --- zoom -------------------------------------------------------------------

function zoomHook() {
  const { h, sent } = hook()
  h.el.clientWidth = 1000
  h.el.clientHeight = 500
  h.baseColumns = 5
  h.el.getBoundingClientRect = () => ({ left: 0, top: 0, width: 1000, height: 500 })
  h.setIndex({ library: "a", revision: 1, sections: [section(400), { ...section(400), id: "2020-02" }] })
  h.el.scrollTop = 3000
  return { h, sent }
}

test("zooming changes the columns and keeps the photo under the fingers where it was", () => {
  const { h } = zoomHook()
  assert.equal(h.columns, 5)
  const focus = h.itemAtPoint(500, 250)
  h.zoomTo(100, 500, 250)
  assert.equal(h.columns, 10)
  assert.equal(h.metrics.cell * 10 + h.metrics.gap * 9, 1000)
  const row = Math.floor(focus.item / h.columns)
  const middle = h.offsets[focus.index] + h.metrics.header + row * (h.metrics.cell + h.metrics.gap) + h.metrics.cell / 2
  assert(Math.abs(middle - h.el.scrollTop - 250) < 1)
})

test("a tile can be no smaller than the minimum and no bigger than the screen", () => {
  const { h } = zoomHook()
  h.zoomTo(1, 500, 250)
  assert.equal(h.zoomCell, 56)
  h.zoomTo(100000, 500, 250)
  assert.equal(h.columns, 1)
  assert.equal(h.metrics.cell, 1000)
})

test("a pinch is a preview until the fingers lift, then it becomes a tile size", () => {
  const { h } = zoomHook()
  const cell = h.metrics.cell
  h.movePinch(0.5, 500, 250)
  assert.equal(h.columns, 5, "nothing is laid out again while the fingers are down")
  h.endPinch()
  assert.equal(h.columns, 10)
  assert(Math.abs(h.zoomCell - cell * 0.5) < 1)
  assert.equal(h.pinch, null)
})

test("the scale of a pinch is held where the tiles cannot go further", () => {
  const { h } = zoomHook()
  assert(h.clampScale(0.001) >= 56 / h.metrics.cell - 1e-9)
  assert(h.clampScale(1000) <= 1000 / h.metrics.cell + 1e-9)
  assert.equal(h.clampScale(1), 1)
})

test("a trackpad pinch (ctrl + wheel) zooms, and a plain wheel is left to scroll", () => {
  const { h } = zoomHook()
  let prevented = 0
  const wheel = (extra) => ({ deltaY: -60, clientX: 500, clientY: 250, preventDefault: () => prevented++, ...extra })
  h.wheel(wheel({ ctrlKey: false }))
  assert.equal(prevented, 0)
  assert.equal(h.pinch, null)
  h.wheel(wheel({ ctrlKey: true }))
  clearTimeout(h.wheelTimer)
  assert.equal(prevented, 1)
  assert(h.pinch.scale > 1)
  h.endPinch()
  assert(h.columns < 5)
})

test("two fingers pinch; one finger does not; iOS gesture events defer to the touches", () => {
  const { h } = zoomHook()
  const finger = (x, y) => ({ clientX: x, clientY: y })
  let prevented = 0
  const touch = (touches) => ({ touches, preventDefault: () => prevented++ })

  h.touchStart(touch([finger(500, 250)]))
  h.touchMove(touch([finger(500, 250)]))
  assert.equal(h.pinch, null)

  h.touchStart(touch([finger(400, 250), finger(600, 250)]))
  h.touchMove(touch([finger(300, 250), finger(700, 250)]))
  assert.equal(prevented, 1)
  assert(Math.abs(h.pinch.scale - 2) < 0.01)
  h.gesture({ scale: 9, preventDefault() {} }, "change")
  assert(Math.abs(h.pinch.scale - 2) < 0.01, "the gesture event is ignored during a touch pinch")
  h.touchEnd(touch([finger(500, 250)]))
  assert.equal(h.pinch, null)
  assert(h.columns < 5, "pinching out (fingers apart) makes the tiles bigger: fewer columns")
})

test("+ and - step the columns, 0 goes back; typing in a field does not zoom", () => {
  const { h } = zoomHook()
  const key = (k, extra = {}) => { let stopped = false; h.zoomKey({ key: k, target: {}, preventDefault: () => (stopped = true), ...extra }); return stopped }
  assert(key("-"))
  assert.equal(h.columns, 6)
  assert(key("+"))
  assert.equal(h.columns, 5)
  assert(key("+"))
  assert.equal(h.columns, 4)
  assert(key("0"))
  assert.equal(h.zoomCell, null)
  assert.equal(h.columns, 5)
  assert(!key("-", { target: { tagName: "INPUT" } }))
  assert(!key("-", { ctrlKey: true }))
  assert.equal(h.columns, 5)
})
