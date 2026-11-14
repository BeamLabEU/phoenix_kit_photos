import { test } from "node:test"
import assert from "node:assert/strict"
import { dateOf, monthOf, daysOf, dayOn, dayAt, neighbour, placeOf } from "../js/days.js"

// A long day split into two windows, a chapter cutting February, and March.
const sections = [
  { id: "2022-02", days_list: [{ id: "2022-02-01", count: 2 }, { id: "2022-02-24", count: 200 }, { id: "2022-02-24:200", count: 13 }] },
  { id: "c:trip", days_list: [{ id: "2022-02-26", count: 3 }] },
  { id: "2022-03", days_list: [{ id: "2022-03-05", count: 1 }] }
]

test("a window id's date and month", () => {
  assert.equal(dateOf("2022-02-24:200"), "2022-02-24")
  assert.equal(monthOf("2022-02-24"), "2022-02")
  assert.equal(monthOf("2022-02"), "2022-02")
})

test("days: a long day is one, with both windows; positions run on across sections", () => {
  const days = daysOf(sections)
  assert.deepEqual(days.map((d) => [d.date, d.start, d.count]), [
    ["2022-02-01", 0, 2],
    ["2022-02-24", 2, 213],
    ["2022-02-26", 215, 3],
    ["2022-03-05", 218, 1]
  ])
  assert.deepEqual(days[1].windows, ["2022-02-24", "2022-02-24:200"])
  assert.deepEqual(days[1].sizes, [200, 13])
})

test("the day of a date, of a position, and its neighbours", () => {
  const days = daysOf(sections)
  assert.equal(dayOn(days, "2022-02-26").start, 215)
  assert.equal(dayOn(days, "2022-02-25"), null)
  assert.equal(dayAt(days, 0).date, "2022-02-01")
  assert.equal(dayAt(days, 214).date, "2022-02-24")
  assert.equal(dayAt(days, 218).date, "2022-03-05")
  assert.equal(dayAt(days, 219), null)
  assert.equal(neighbour(days, "2022-02-24", -1).date, "2022-02-01")
  assert.equal(neighbour(days, "2022-02-26", 1).date, "2022-03-05")
  assert.equal(neighbour(days, "2022-03-05", 1), null)
  assert.equal(neighbour(days, "2022-01-01", 1), null)
})

test("where a date stands: its section and the place of its first photo", () => {
  assert.deepEqual(placeOf(sections, "2022-02-24"), { section: 0, item: 2 })
  assert.deepEqual(placeOf(sections, "2022-02-26"), { section: 1, item: 0 })
  assert.deepEqual(placeOf(sections, "2022-03"), { section: 2, item: 0 })
  assert.deepEqual(placeOf(sections, "2022-02"), { section: 0, item: 0 })
  assert.equal(placeOf(sections, "2021-01"), null)
})
