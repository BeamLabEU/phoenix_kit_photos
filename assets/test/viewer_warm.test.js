import { test } from "node:test"
import assert from "node:assert/strict"

import { constrained, parseAspect, displayedPx, originalsToWarm, installViewerWarm } from "../js/viewer_warm.js"

const wide = { width: 2400, height: 1800, dpr: 1 } // a big window a 4:3 photo can fill
const detail = (over = {}) => ({
  prev: { original: "/f/p/original/aa", aspect: "4 / 3" },
  next: { original: "/f/n/original/bb", aspect: "4 / 3" },
  direction: "",
  box: wide,
  ...over
})

test("parseAspect reads core's 'w / h', plain numbers, and refuses nonsense", () => {
  assert.equal(parseAspect("4 / 3"), 4 / 3)
  assert.equal(parseAspect("3024 / 4032"), 0.75)
  assert.equal(parseAspect("1.5"), 1.5)
  assert.equal(parseAspect(2), 2)
  for (const bad of ["", null, undefined, "x / y", "0 / 5", "5 / 0", -1]) {
    assert.equal(parseAspect(bad), null, String(bad))
  }
})

test("a picture is fitted inside the box: displayed width follows the aspect", () => {
  // landscape in a wide window is limited by the width…
  assert.equal(displayedPx("4 / 3", { width: 2400, height: 1800, dpr: 1 }), 2400)
  // …a portrait one by the height, so it is narrow however wide the window
  assert.equal(displayedPx("3 / 4", { width: 2400, height: 1000, dpr: 1 }), 750)
  assert.equal(displayedPx("3 / 4", { width: 2400, height: 1000, dpr: 2 }), 1500)
  // unknown shape: assume it spans the width
  assert.equal(displayedPx(null, { width: 1200, height: 800, dpr: 2 }), 2400)
  assert.equal(displayedPx("4 / 3", null), 0)
})

test("a picture large covers warms no original", () => {
  assert.deepEqual(originalsToWarm(detail({ box: { width: 1400, height: 1000, dpr: 1 } })), [])
  assert.deepEqual(originalsToWarm(detail({ box: { width: 1920 * 1.1, height: 9999, dpr: 1 } })), [],
    "the boundary is covered")
})

test("a portrait photo in a wide window is NOT worth an original", () => {
  // The case that wasted 1.7 MB: 3024x4032 in a 2400-wide, ~1000-high window
  // lights 750 device px at dpr 1 and 1500 at dpr 2 — `large` is plenty.
  const portrait = { prev: null, next: { original: "/f/n/original/bb", aspect: "3024 / 4032" } }
  assert.deepEqual(originalsToWarm(detail({ ...portrait, box: { width: 2400, height: 1000, dpr: 2 } })), [])
})

test("a landscape photo filling a wide retina window warms one original: the next, before any step", () => {
  assert.deepEqual(originalsToWarm(detail({ box: { width: 1600, height: 1200, dpr: 2 } })),
    ["/f/n/original/bb"])
})

test("after stepping back, the previous one is warmed instead", () => {
  assert.deepEqual(originalsToWarm(detail({ direction: "prev" })), ["/f/p/original/aa"])
  assert.deepEqual(originalsToWarm(detail({ direction: "next" })), ["/f/n/original/bb"])
})

test("no original on a neighbour, nothing to warm", () => {
  assert.deepEqual(originalsToWarm(detail({ next: { original: "", aspect: "4 / 3" } })), [])
  assert.deepEqual(originalsToWarm(detail({ next: { aspect: "4 / 3" } })), [])
  assert.deepEqual(originalsToWarm(detail({ next: null })), [])
  assert.deepEqual(originalsToWarm(null), [])
})

test("data-saver and slow lines never warm an original", () => {
  assert.equal(constrained({ saveData: true }), true)
  assert.equal(constrained({ effectiveType: "3g" }), true)
  assert.equal(constrained({ effectiveType: "slow-2g" }), true)
  assert.equal(constrained({ effectiveType: "4g" }), false)
  assert.equal(constrained(undefined), false)
  assert.deepEqual(originalsToWarm(detail(), { saveData: true }), [])
})

function fakeWin(connection) {
  const handlers = {}
  const fetched = []
  const priorities = []
  function Img() {}
  Object.defineProperty(Img.prototype, "src", {
    set(v) {
      fetched.push(v)
      priorities.push(this.fetchPriority)
    }
  })
  const win = {
    navigator: { connection },
    addEventListener: (n, fn) => (handlers[n] = fn)
  }
  return { win, Img, fetched, priorities, fire: (n, d) => handlers[n]({ detail: d }) }
}

test("the listener fetches at low priority, once per URL across announcements", () => {
  const { win, Img, fetched, priorities, fire } = fakeWin({ effectiveType: "4g" })
  installViewerWarm(win, Img)
  fire("pk:viewer-neighbours", detail())
  fire("pk:viewer-neighbours", detail())
  assert.deepEqual(fetched, ["/f/n/original/bb"])
  assert.deepEqual(priorities, ["low"])
})

test("it shares core's page-wide map, so a URL core already warmed is not fetched again", () => {
  const { win, Img, fetched, fire } = fakeWin()
  win.__pkWarmedUrls = { "/f/n/original/bb": true }
  installViewerWarm(win, Img)
  fire("pk:viewer-neighbours", detail())
  assert.deepEqual(fetched, [])
})

test("installing without a window is harmless", () => {
  assert.equal(installViewerWarm(undefined), null)
  assert.equal(installViewerWarm({}), null)
})
