import test from "node:test"
import assert from "node:assert/strict"
import { BLOCK, SlideStore, blocksAround, chooseSource, flattenDays, locate, wantWidth } from "../js/slides.js"

const sections = [
  { id: "2024-01", days_list: [{ id: "2024-01-05", count: 30 }, { id: "2024-01-09", count: 5 }] },
  { id: "2024-02", days_list: [{ id: "2024-02-01", count: 500 }, { id: "2024-02-01:500", count: 20 }] }
]

test("flattenDays lays the days end to end", () => {
  const { days, total } = flattenDays(sections)
  assert.equal(total, 555)
  assert.deepEqual(days.map((d) => d.start), [0, 30, 35, 535])
})

test("flattenDays skips empty days and tolerates no sections", () => {
  assert.deepEqual(flattenDays([{ days_list: [{ id: "a", count: 0 }] }]), { days: [], total: 0 })
  assert.deepEqual(flattenDays(undefined), { days: [], total: 0 })
})

test("locate finds the day and the position, at every edge", () => {
  const { days } = flattenDays(sections)
  assert.deepEqual(locate(days, 0), { day: days[0], position: 0 })
  assert.deepEqual(locate(days, 29), { day: days[0], position: 29 })
  assert.deepEqual(locate(days, 30), { day: days[1], position: 0 })
  assert.deepEqual(locate(days, 554), { day: days[3], position: 19 })
  assert.equal(locate(days, 555), null)
  assert.equal(locate(days, -1), null)
})

test("blocksAround asks for aligned blocks inside one day", () => {
  const { days, total } = flattenDays(sections)
  const blocks = blocksAround(days, total, 20, 2)
  assert.deepEqual(blocks.map((b) => [b.window, b.from, b.start]), [["2024-01-05", 12, 12]])
  // 11 is the last of the block before it
  assert.equal(blocksAround(days, total, 14, 3).length, 2)
})

test("blocksAround spans a day boundary and clamps to the ends", () => {
  const { days, total } = flattenDays(sections)
  const blocks = blocksAround(days, total, 31, 3)
  assert.deepEqual(blocks.map((b) => b.window), ["2024-01-05", "2024-01-09"])
  assert.equal(blocksAround(days, total, 0, 5).length, 1)
  assert.equal(blocksAround(days, total, 554, 50).at(-1).window, "2024-02-01:500")
  assert.deepEqual(blocksAround([], 0, 0, 5), [])
})

test("SlideStore puts slides at global positions and reports only the new ones", () => {
  const store = new SlideStore(sections)
  assert.deepEqual(store.put("2024-01-09", 0, [{ id: "a" }, { id: "b" }]), [30, 31])
  assert.equal(store.get(31).id, "b")
  assert.equal(store.indexOf("a"), 30)
  assert.equal(store.indexOf("zzz"), -1)
  assert.deepEqual(store.put("2024-01-09", 0, [{ id: "a2" }]), [])
  assert.equal(store.get(30).id, "a2")
})

test("SlideStore ignores an unknown window and clips items past the end", () => {
  const store = new SlideStore(sections)
  assert.deepEqual(store.put("nope", 0, [{ id: "x" }]), [])
  const last = store.put("2024-02-01:500", 12, new Array(30).fill(0).map((_, i) => ({ id: `i${i}` })))
  assert.equal(last.at(-1), 554)
})

test("missing skips blocks already asked for or fully known", () => {
  const store = new SlideStore(sections)
  const first = store.missing(20, 2)
  assert.equal(first.length, 1)
  store.markAsked(first[0])
  assert.equal(store.missing(20, 2).length, 0)
  store.forget(first[0].window, first[0].from)
  assert.equal(store.missing(20, 2).length, 1)

  const items = new Array(BLOCK).fill(0).map((_, i) => ({ id: `k${i}` }))
  store.put("2024-01-05", 12, items)
  store.forget("2024-01-05", 12)
  assert.equal(store.missing(20, 2).length, 0)
})

test("wantWidth is the screen in device pixels, within bounds", () => {
  assert.equal(wantWidth({ innerWidth: 390, devicePixelRatio: 3 }), 1170)
  assert.equal(wantWidth({ innerWidth: 100, devicePixelRatio: 1 }), 400)
  assert.equal(wantWidth({ innerWidth: 3000, devicePixelRatio: 2 }), 4096)
  assert.equal(wantWidth({ innerWidth: 800 }), 800)
})

const sources = [
  { url: "r", type: "video/mp4", role: "rendition" },
  { url: "o", type: "video/quicktime", role: "original" }
]

test("chooseSource keeps HDR for a screen and browser that can show it", () => {
  assert.equal(chooseSource(sources, { hdrScreen: true, canPlay: () => true }).url, "o")
})

test("chooseSource uses the rendition on an SDR screen, or when the original will not play", () => {
  assert.equal(chooseSource(sources, { hdrScreen: false, canPlay: () => true }).url, "r")
  assert.equal(chooseSource(sources, { hdrScreen: true, canPlay: () => false }).url, "r")
})

test("chooseSource falls back to the original when there is no rendition, and to null with nothing", () => {
  assert.equal(chooseSource([sources[1]], { hdrScreen: false, canPlay: () => false }).url, "o")
  assert.equal(chooseSource([], { hdrScreen: true, canPlay: () => true }), null)
  assert.equal(chooseSource(undefined, { hdrScreen: true, canPlay: () => true }), null)
})
