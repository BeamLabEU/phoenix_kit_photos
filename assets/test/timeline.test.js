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
    fetchedAt: new Map(), lastReload: 0,
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
  h.beginPositionInput({ type: "wheel" })
  h.el.scrollTop = 100
  h.handleScroll()
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

const needs = (sent) => sent.filter(([, event]) => event === "timeline:need_window").map(([, , payload]) => payload.window)

test("a failing tile asks for the windows on screen again, once for a whole screen of failures", () => {
  const { h, sent } = hook()
  h.setIndex({ library: "a", revision: 1, sections: [section(1)] })
  h.setWindow({ section: "2020-01-01", revision: 1, items: [{ id: "a", thumb: "/old" }] })
  sent.length = 0
  for (let i = 0; i < 30; i++) h.imageFailed()
  assert.deepEqual(needs(sent), ["2020-01-01"])
  assert.equal(h.windows.get("2020-01-01")[0].thumb, "/old", "the old tiles stay until the answer comes")
  h.setWindow({ section: "2020-01-01", revision: 1, items: [{ id: "a", thumb: "/new" }] })
  assert.equal(h.windows.get("2020-01-01")[0].thumb, "/new")
})

test("a window still in flight is not asked for twice", () => {
  const { h, sent } = hook()
  h.setIndex({ library: "a", revision: 1, sections: [section(1)] })
  sent.length = 0
  h.reloadWindows()
  assert.deepEqual(needs(sent), [])
})

test("a tab that wakes asks again only for windows older than the limit", () => {
  const { h, sent } = hook()
  h.setIndex({ library: "a", revision: 1, sections: [section(501)] })
  h.setWindow({ section: "2020-01-01", revision: 1, items: [{ id: "a" }] })
  h.setWindow({ section: "2020-01-01:500", revision: 1, items: [{ id: "b" }] })
  h.fetchedAt.set("2020-01-01", Date.now() - 2 * 60 * 60 * 1000)
  sent.length = 0
  h.reloadWindows({ olderThan: 60 * 60 * 1000 })
  assert.deepEqual(needs(sent), ["2020-01-01"])
})

test("a fresh mount restores each library's position after reload, including a changed width", () => {
  const previous = globalThis.window
  const values = new Map()
  globalThis.window = { sessionStorage: {
    getItem: key => values.get(key) ?? null,
    setItem: (key, value) => values.set(key, value)
  } }
  try {
    const payload = { library: "a", revision: 1, sections: [section(501)] }
    const { h } = hook()
    h.el.clientWidth = 816
    h.setIndex(payload)
    h.beginPositionInput({ type: "wheel" })
    h.el.scrollTop = 40 + 20 * 164
    h.handleScroll()
    const anchor = h.captureAnchor()
    const { h: restored } = hook()
    restored.el.clientWidth = 375
    restored.setIndex(payload)
    assert.equal(restored.captureAnchor().id, anchor.id)
    assert(Math.abs(restored.captureAnchor().item - anchor.item) < restored.columns)
    restored.setIndex({ ...payload, library: "b" })
    assert.equal(restored.el.scrollTop, restored.offsets.at(-1) - restored.el.clientHeight)
    restored.setIndex(payload)
    assert(Math.abs(restored.captureAnchor().item - anchor.item) < restored.columns)
    values.set(restored.positionKey(), '{broken')
    assert.equal(restored.storedPosition(), null)
  } finally {
    if (previous === undefined) delete globalThis.window
    else globalThis.window = previous
  }
})

test("repeated wake layouts retain the exact partial row with fractional cell sizes", () => {
  const { h } = hook()
  h.el.clientWidth = 997
  h.setIndex({ library: "a", revision: 1, sections: [section(501)] })
  const stride = h.metrics.cell + h.metrics.gap
  for (const top of [40 + 23 * stride, 40 + 23.37 * stride]) {
    h.el.scrollTop = top
    for (let wake = 0; wake < 50; wake++) {
      const anchor = JSON.parse(JSON.stringify(h.captureAnchor()))
      h.relayout(anchor)
      assert(Math.abs(h.el.scrollTop - top) < 0.001, `position drifted on wake ${wake}`)
    }
  }
})

test("a floating header is counted once across repeated wakes and inset changes", () => {
  const { h } = hook()
  let inset = 56
  h.readInset = () => inset
  h.el.clientWidth = 997
  h.setIndex({ library: "a", revision: 1, sections: [section(501)] })
  h.el.scrollTop = 3456.75
  const initial = h.el.scrollTop
  for (let wake = 0; wake < 50; wake++) {
    h.handleResize()
    assert.equal(h.el.scrollTop, initial)
  }
  const anchor = h.captureAnchor()
  inset = 80
  h.relayout(anchor)
  assert.equal(h.el.scrollTop, initial, "leading space and visible header offset cancel exactly")
  assert.equal(h.captureAnchor().item, anchor.item)
})

test("the bookmark follows scrolling and sits in a photo row gap below the header", () => {
  const { h } = hook()
  h.el.clientWidth = 997
  h.readInset = () => 56
  h.setIndex({ library: "a", revision: 1, sections: [section(501)] })
  h.beginPositionInput({ type: "wheel" })
  h.el.scrollTop = 3456.75
  h.handleScroll()
  const top = h.bookmarkTop()
  const stride = h.metrics.cell + h.metrics.gap
  const row = (top + h.metrics.gap / 2 - h.offsets[0] - h.metrics.header) / stride
  assert(Math.abs(row - Math.round(row)) < 1e-9, "marker is centered in a row gap")
  assert(top >= h.el.scrollTop + h.inset, "marker clears the floating header")
  h.el.scrollTop -= stride * 2
  h.handleScroll()
  assert(Math.abs(h.bookmarkTop() - (top - stride * 2)) < 1e-9, "marker follows the current row")
  assert.equal(h.bookmarkAnchor.delta, h.captureAnchor().delta)
  h.setIndex({ library: "b", revision: 2, sections: [] })
  assert.equal(h.bookmarkTop(), null)
})

test("background and reconnect scrolls cannot replace the saved place with the bottom", () => {
  const previous = globalThis.window
  const values = new Map()
  globalThis.window = { sessionStorage: {
    getItem: key => values.get(key) ?? null,
    setItem: (key, value) => values.set(key, value)
  } }
  try {
    const payload = { library: "a", revision: 1, sections: [section(501)] }
    const { h } = hook()
    h.el.clientWidth = 997
    h.setIndex(payload)
    h.beginPositionInput({ type: "wheel" })
    h.el.scrollTop = 2345.5
    h.handleScroll()
    const saved = values.get(h.positionKey())
    h.freezePosition()
    // Safari may move the scroller before visibilitychange or resize is delivered.
    h.el.scrollTop = h.offsets.at(-1) - h.el.clientHeight
    h.handleResize()
    h.reconnected()
    h.setIndex({ ...payload, revision: 2 })
    assert.equal(h.el.scrollTop, 2345.5)
    assert.equal(values.get(h.positionKey()), saved)
    const { h: remounted } = hook()
    remounted.el.clientWidth = 997
    remounted.setIndex(payload)
    remounted.el.scrollTop = remounted.offsets.at(-1) - remounted.el.clientHeight
    remounted.handleScroll()
    assert.equal(remounted.el.scrollTop, 2345.5, "remount also protects against late browser restoration")
    remounted.beginPositionInput({ type: "wheel" })
    remounted.el.scrollTop = 2600
    remounted.handleScroll()
    assert.equal(remounted.bookmarkAnchor.delta, remounted.captureAnchor().delta)
    assert.notEqual(values.get(remounted.positionKey()), saved, "deliberate scrolling updates the bookmark")
  } finally {
    if (previous === undefined) delete globalThis.window
    else globalThis.window = previous
  }
})

test("incidental scrolling and clicking back into Safari cannot move the bookmark", () => {
  const { h } = hook()
  h.el.clientWidth = 997
  h.el.getBoundingClientRect = () => ({ right: 997 })
  h.setIndex({ library: "a", revision: 1, sections: [section(501)] })
  h.beginPositionInput({ type: "wheel" })
  h.el.scrollTop = 2345
  h.handleScroll()
  const bookmark = h.bookmarkAnchor
  h.positionInput = false // the scroll gesture finished
  h.el.scrollTop = h.offsets.at(-1) - h.el.clientHeight
  h.handleScroll() // automatic browser movement, even without a visibility event
  assert.deepEqual(h.bookmarkAnchor, bookmark)
  h.freezePosition() // window blur, even though the page remains visible
  h.beginPositionInput({ type: "pointerdown", clientX: 400 })
  assert.equal(h.frozenAnchor, bookmark, "activating the window does not unlock restoration")
  h.handleScroll() // focus
  assert.equal(h.el.scrollTop, 2345)
  h.beginPositionInput({ type: "keydown", key: "a" })
  assert.equal(h.frozenAnchor, bookmark, "ordinary typing does not unlock scrolling")
  h.beginPositionInput({ type: "wheel" })
  h.el.scrollTop = 2500
  h.handleScroll()
  assert.equal(h.bookmarkAnchor.delta, h.captureAnchor().delta)
  assert.notDeepEqual(h.bookmarkAnchor, bookmark)
  clearTimeout(h.positionInputTimer)
})

test("closing the browser loses tab storage but preserves the library bookmark", () => {
  const previous = globalThis.window
  const tab = new Map()
  const durable = new Map()
  const storage = values => ({ getItem: key => values.get(key) ?? null,
    setItem: (key, value) => values.set(key, value) })
  globalThis.window = { sessionStorage: storage(tab), localStorage: storage(durable) }
  try {
    const payload = { library: "a", revision: 1, sections: [section(501)] }
    const { h } = hook()
    h.el.clientWidth = 997
    h.setIndex(payload)
    h.beginPositionInput({ type: "wheel" })
    h.el.scrollTop = 2345.5
    h.handleScroll()
    h.freezePosition()
    tab.clear() // a newly opened browser session has no previous sessionStorage
    const { h: reopened } = hook()
    reopened.el.clientWidth = 997
    reopened.setIndex(payload)
    assert.equal(reopened.el.scrollTop, 2345.5)
    assert.equal(reopened.bookmarkTop(), h.bookmarkTop())
    clearTimeout(h.positionInputTimer)
  } finally {
    if (previous === undefined) delete globalThis.window
    else globalThis.window = previous
  }
})

test("an open tab keeps its own bookmark and unavailable storage does not block the other copy", () => {
  const previous = globalThis.window
  const tab = new Map()
  const durable = new Map()
  const storage = values => ({ getItem: key => values.get(key) ?? null,
    setItem: (key, value) => values.set(key, value) })
  globalThis.window = { sessionStorage: storage(tab), localStorage: storage(durable) }
  try {
    const { h } = hook()
    h.setIndex({ library: "a", revision: 1, sections: [section(501)] })
    const key = h.positionKey()
    const original = h.storedPosition()
    tab.set(key, JSON.stringify({ anchor: { ...original.anchor, item: 10 } }))
    durable.set(key, JSON.stringify({ anchor: { ...original.anchor, item: 20 } }))
    assert.equal(h.storedPosition().anchor.item, 10, "open tabs retain independent positions")
    tab.set(key, '{broken')
    assert.equal(h.storedPosition().anchor.item, 20)
    globalThis.window.sessionStorage = {
      getItem() { throw Error("unavailable") }, setItem() { throw Error("unavailable") }
    }
    assert.equal(h.storedPosition().anchor.item, 20)
    h.rememberPosition()
    assert.equal(JSON.parse(durable.get(key)).anchor.item, h.bookmarkAnchor.item)
    globalThis.window.sessionStorage = storage(tab)
    globalThis.window.localStorage = {
      getItem() { throw Error("unavailable") }, setItem() { throw Error("unavailable") }
    }
    h.rememberPosition()
    assert.equal(h.storedPosition().anchor.item, h.bookmarkAnchor.item)
  } finally {
    if (previous === undefined) delete globalThis.window
    else globalThis.window = previous
  }
})

test("a saved place survives a change of style", () => {
  const { h } = hook()
  h.el.clientWidth = 816
  h.setIndex({ library: "a", revision: 1, sections: [section(400)] })
  h.el.scrollTop = 40 + 30 * 164
  const anchor = h.captureAnchor()
  assert.equal(anchor.item, 150)
  h.styleId = "details"
  h.relayout(anchor)
  const middle = h.tileMiddle({ index: 0, item: 150 })
  assert(Math.abs(middle - h.el.scrollTop) < 80, "the same photo is at the top")
})

test("a style that places whole photos makes do with the month's average until the ratios come", () => {
  const { h, sent } = hook()
  h.el.clientWidth = 816
  h.setIndex({ library: "a", revision: 1, sections: [{ ...section(40), sum_aspect: 60 }] })
  h.morphTo = id => { h.styleId = id; h.relayout(null) }
  sent.length = 0
  h.setStyle("rows")
  assert(sent.some(([, event]) => event === "timeline:aspects"))
  assert.equal(h.styleId, "grid", "waits for the answer")
  const bytes = btoa(String.fromCharCode(...Array(40).fill(180)))
  h.setAspects({ aspects: { "2020-01": bytes }, revision: 1 })
  assert.equal(h.styleId, "rows")
  assert.equal(h.aspects.get("2020-01").length, 40)
  clearTimeout(h.aspectsTimer)
})

test("ratios are kept whatever index they came with: the server sends a month only once", () => {
  const { h } = hook()
  h.setIndex({ library: "a", revision: 2, sections: [section(2)] })
  h.setAspects({ aspects: { "2020-01": btoa("xy") }, revision: 1 })
  assert.equal(h.aspects.get("2020-01").length, 2)
})

test("ratios that came while the viewer was open are not lost to a later refresh", () => {
  const { h } = hook()
  h.setIndex({ library: "a", revision: 1, sections: [section(2)] })
  h.pager = { destroy() {} }
  h.setIndex({ library: "a", revision: 2, sections: [section(2)], aspects: { "2020-01": btoa("xy") } })
  h.setIndex({ library: "a", revision: 3, sections: [section(2)] })
  h.pager = null
  h.applyDeferred()
  assert.equal(h.revision, 3)
  assert.equal(h.aspects.get("2020-01").length, 2)
})

test("the ratios of the last library are dropped with it", () => {
  const { h } = hook()
  h.setIndex({ library: "a", revision: 1, sections: [section(2)], aspects: { "2020-01": btoa("xy") } })
  assert.equal(h.aspects.get("2020-01").length, 2)
  h.setIndex({ library: "b", revision: 2, sections: [section(2)] })
  assert.equal(h.aspects.get("2020-01"), undefined)
})

test("the style a person picked wins over the host's, and nonsense is the plain grid", () => {
  const { h } = hook()
  const stored = { value: null }
  globalThis.window = globalThis.window || {}
  const before = window.localStorage
  window.localStorage = { getItem: () => stored.value, setItem() {}, removeItem() {} }
  h.el.dataset.style = "mosaic"
  h.el.dataset.styles = "grid film mosaic"
  assert.equal(h.startingStyle(), "mosaic")
  stored.value = "film"
  assert.equal(h.startingStyle(), "film")
  stored.value = "feed"
  assert.equal(h.startingStyle(), "mosaic", "a style the host does not offer")
  stored.value = "<script>"
  assert.equal(h.startingStyle(), "mosaic")
  h.el.dataset.style = "nope"
  assert.equal(h.startingStyle(), "grid")
  window.localStorage = before
})

const selecting = () => {
  const { h, sent } = hook()
  h.el.dataset.selectable = "true"
  h.el.clientWidth = 816
  h.setIndex({ library: "a", revision: 1, sections: [section(3), { ...section(2), id: "2020-02", days_list: [{ id: "2020-02-01", count: 2 }] }] })
  h.setWindow({ section: "2020-01-01", revision: 1, items: [{ id: "a" }, { id: "b" }, { id: "c" }] })
  return { h, sent }
}
const click = (over = {}) => ({ target: { closest: () => null }, ...over })
const tile = (global) => ({ dataset: { global: String(global) } })

test("a plain click opens until something is chosen; then a click chooses", () => {
  const { h } = selecting()
  const opened = []
  h.openTile = (id) => opened.push(id)
  h.tileClick(click(), tile(0), "a")
  assert.deepEqual(opened, ["a"])
  h.tileClick(click({ metaKey: true }), tile(0), "a")
  assert.deepEqual(h.selectedIds(), ["a"])
  h.tileClick(click(), tile(1), "b")
  assert.deepEqual(opened, ["a"], "not opened")
  assert.deepEqual(h.selectedIds(), ["a", "b"])
  h.tileClick(click(), tile(1), "b")
  assert.deepEqual(h.selectedIds(), ["a"], "a second click lets go")
})

test("the circle on a tile starts a selection without opening it", () => {
  const { h } = selecting()
  h.openTile = () => assert.fail("opened")
  h.tileClick(click({ target: { closest: s => (s === ".pkt-check" ? {} : null) } }), tile(2), "c")
  assert.deepEqual(h.selectedIds(), ["c"])
})

test("without `selectable` a click only ever opens", () => {
  const { h } = selecting()
  h.el.dataset.selectable = "false"
  const opened = []
  h.openTile = (id) => opened.push(id)
  h.tileClick(click({ metaKey: true }), tile(0), "a")
  assert.deepEqual(opened, ["a"])
  assert.deepEqual(h.selectedIds(), [])
})

test("shift takes the run between two tiles at once when they are on hand", () => {
  const { h, sent } = selecting()
  h.toggleSelected("a", 0)
  sent.length = 0
  h.tileClick(click({ shiftKey: true }), tile(2), "c")
  assert.deepEqual(h.selectedIds().sort(), ["a", "b", "c"])
  assert.equal(sent.filter(([, e]) => e === "timeline:range").length, 0)
})

test("a run through what has not been fetched is asked of the server", () => {
  const { h, sent } = selecting()
  h.toggleSelected("a", 0)
  sent.length = 0
  h.tileClick(click({ shiftKey: true }), tile(4), "e")
  assert.deepEqual(sent.find(([, e]) => e === "timeline:range")[2], { from: 0, to: 4, mode: "add", revision: 1 })
  h.applyRange({ ids: ["a", "b", "c", "d", "e"], mode: "add", revision: 1 })
  assert.equal(h.selectedIds().length, 5)
})

test("an answer for an older index is dropped", () => {
  const { h } = selecting()
  h.applyRange({ ids: ["x"], mode: "add", revision: 0 })
  assert.deepEqual(h.selectedIds(), [])
})

test("a month's circle takes the month, and a second press lets it go", () => {
  const { h } = selecting()
  h.selectSection(0)
  assert.deepEqual(h.selectedIds().sort(), ["a", "b", "c"])
  h.selectSection(0)
  assert.deepEqual(h.selectedIds(), [])
})

test("what is chosen in one library does not follow to the next", () => {
  const { h } = selecting()
  h.toggleSelected("a", 0)
  h.setIndex({ library: "b", revision: 2, sections: [section(1)] })
  assert.deepEqual(h.selectedIds(), [])
  assert.equal(h.selecting(), false)
})

test("a refresh of the same library keeps what is chosen", () => {
  const { h } = selecting()
  h.toggleSelected("a", 0)
  h.setIndex({ library: "a", revision: 2, sections: [section(4)] })
  assert.deepEqual(h.selectedIds(), ["a"])
})

test("a refresh lets go of the anchor: its position may now be another photo", () => {
  const { h } = selecting()
  h.toggleSelected("a", 0)
  h.setIndex({ library: "a", revision: 2, sections: [section(4)] })
  assert.equal(h.selectAnchor, null)
  h.openTile = () => {}
  h.tileClick(click({ shiftKey: true }), tile(2), "c")
  assert.deepEqual(h.selectedIds().sort(), ["a", "c"], "toggles instead of taking a wrong run")
})

test("a selection stops at its limit, however it was built", () => {
  const { h } = selecting()
  h.selectionLimit = () => 2
  h.addSelected(["a", "b", "c"])
  assert.deepEqual(h.selectedIds(), ["a", "b"])
  h.toggleSelected("c", 2)
  assert.deepEqual(h.selectedIds(), ["a", "b"])
})

test("this moment is the photos taken close together around the last one touched", () => {
  const { h } = selecting()
  h.setWindow({ section: "2020-01-01", revision: 1, items: [
    { id: "a", taken_at: "2020-01-01T10:00:00Z" },
    { id: "b", taken_at: "2020-01-01T10:02:00Z" },
    { id: "c", taken_at: "2020-01-01T14:00:00Z" }
  ] })
  h.toggleSelected("b", 1)
  h.selectMoment()
  assert.deepEqual(h.selectedIds().sort(), ["a", "b"])
})

test("this day takes every slice of a big day, and nothing of the next", () => {
  const { h, sent } = hook()
  h.el.dataset.selectable = "true"
  h.el.clientWidth = 816
  const days = [{ id: "2020-01-01", count: 500 }, { id: "2020-01-01:500", count: 20 }, { id: "2020-01-02", count: 3 }]
  h.setIndex({ library: "a", revision: 1, sections: [{ id: "2020-01", count: 523, days_list: days }] })
  h.selectAnchor = 510
  sent.length = 0
  h.selectDay()
  assert.deepEqual(sent.find(([, e]) => e === "timeline:range")[2], { from: 0, to: 519, mode: "add", revision: 1 })
})

test("the server's answer about a finished action clears the selection", () => {
  const { h } = selecting()
  h.toggleSelected("a", 0)
  h.applySelection({ clear: true })
  assert.deepEqual(h.selectedIds(), [])
})

test("a bulk action sends the ids; a download never goes through the socket", () => {
  const { h, sent } = selecting()
  h.toggleSelected("a", 0)
  sent.length = 0
  h.bulk("trash")
  assert.deepEqual(sent.at(-1).slice(1), ["timeline:bulk", { action: "trash", ids: ["a"] }])
  const downloads = []
  h.download = (ids) => downloads.push(ids)
  sent.length = 0
  h.bulk("download")
  assert.deepEqual(downloads, [["a"]])
  assert.equal(sent.length, 0)
})

test("nothing chosen, nothing asked", () => {
  const { h, sent } = selecting()
  sent.length = 0
  h.bulk("trash")
  assert.equal(sent.length, 0)
})

test("a style a library is too big for cannot be picked, and is left when one arrives", () => {
  const { h } = hook()
  h.el.clientWidth = 816
  const big = { ...section(500), count: 40000, sum_aspect: 60000, days_list: [{ id: "x", count: 40000 }] }
  h.setIndex({ library: "a", revision: 1, sections: [section(3)] })
  h.styleId = "feed"
  h.setIndex({ library: "b", revision: 2, sections: [big] })
  assert.equal(h.styleId, "grid", "the page would be taller than a browser can scroll")
  h.setStyle("feed")
  assert.equal(h.styleId, "grid")
  assert.equal(h.pendingStyle, undefined)
})

// A photo's own address, opened cold: the page brings an index, the hook says hello, and the
// server answers with a new revision; windows asked for in the first one would be refused.
test("an address opens the viewer only in the index that answers the hello", () => {
  const { h, sent } = hook()
  const opened = []
  Object.assign(h, {
    view: { id: "u0", global: 0 },
    pagerEnabled: () => true,
    openPager: (global) => opened.push(global),
    indexCurrent: false
  })

  h.setIndex({ library: "a", revision: 1, sections: [section(1)] })
  assert.deepEqual(opened, [], "the index sent with the page is already old")

  h.setIndex({ library: "a", revision: 2, sections: [section(1)], hello: true })
  assert.deepEqual(opened, [0])
  assert.equal(h.revision, 2)
  const asked = sent.filter(([, event]) => event === "timeline:need_window").map(([, , p]) => p.revision)
  assert.ok(asked.includes(2), "windows are asked for in the current revision")
})

test("an unanswered hello does not keep an address from opening", (t) => {
  t.mock.timers.enable({ apis: ["setTimeout"] })
  const { h, sent } = hook()
  const opened = []
  Object.assign(h, {
    view: { id: "u0", global: 0 },
    pagerEnabled: () => true,
    openPager: (global) => opened.push(global),
    style: () => ({ aspects: false }),
    sections: [section(1)]
  })

  h.sayHello()
  assert.deepEqual(sent.map(([, event]) => event), ["timeline:ready"])
  h.openFromAddress()
  assert.deepEqual(opened, [])
  t.mock.timers.tick(3000)
  assert.deepEqual(opened, [0])
})
