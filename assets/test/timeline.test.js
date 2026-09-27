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
