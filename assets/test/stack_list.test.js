import { test } from "node:test"
import assert from "node:assert/strict"

import { SlideStore } from "../js/slides.js"
import { StackedList } from "../js/stack_list.js"

// A day of `n` photos, all fetched, with stacks at some positions: `{ 2: ["s1", 3] }` makes
// position 2 the cover of stack s1 of 3.
function makeList(n, stacks = {}) {
  const store = new SlideStore([{ id: "2018-07", days_list: [{ id: "2018-07-14", count: n }] }])
  const items = []
  for (let i = 0; i < n; i++) {
    const [stack, count] = stacks[i] || []
    items.push({ id: `p${i}`, stack: stack ? { id: stack, count, title: `T${stack}` } : null })
  }
  store.put("2018-07-14", 0, items)
  return { store, list: new StackedList(store) }
}

const pagesOf = (cover, stack, count) =>
  Array.from({ length: count }, (_v, i) => ({ id: i === 0 ? cover : `${stack}-${i}` }))

test("until its pages arrive a stack is one place, as in the timeline", () => {
  const { list } = list5()
  assert.equal(list.total, 5)
  assert.equal(list.get(2).id, "p2")
  assert.equal(list.toView(3), 3)
  assert.deepEqual(list.fromView(4), { at: 4, page: 0, stack: null })
  assert.equal(list.pageInfo(2), null)
})

function list5() {
  return makeList(5, { 2: ["s1", 3] })
}

test("an open stack's pages come in line, and what follows moves along", () => {
  const { list } = list5()
  list.expand("s1", "p2", pagesOf("p2", "s1", 3))

  assert.equal(list.total, 7)
  assert.deepEqual([0, 1, 2, 3, 4, 5, 6].map((i) => list.get(i).id), ["p0", "p1", "p2", "s1-1", "s1-2", "p3", "p4"])

  assert.equal(list.toView(2), 2)
  assert.equal(list.toView(2, 2), 4)
  assert.equal(list.toView(2, 9), 4) // past the last page: the last page
  assert.equal(list.toView(3), 5)

  assert.equal(list.fromView(3).at, 2)
  assert.equal(list.fromView(3).page, 1)
  assert.deepEqual(list.fromView(5), { at: 3, page: 0, stack: null })

  assert.equal(list.indexOf("s1-2"), 4)
  assert.equal(list.indexOf("p4"), 6)
  assert.equal(list.indexOf("nope"), -1)

  assert.deepEqual(
    (({ id, title, page, count, first, last }) => ({ id, title, page, count, first, last }))(list.pageInfo(3)),
    { id: "s1", title: "Ts1", page: 1, count: 3, first: 2, last: 4 }
  )
  assert.equal(list.pageInfo(5), null)
})

test("two stacks: each shifts what comes after it", () => {
  const { list } = makeList(6, { 1: ["a", 2], 4: ["b", 3] })
  list.expand("b", "p4", pagesOf("p4", "b", 3))
  list.expand("a", "p1", pagesOf("p1", "a", 2))

  assert.equal(list.total, 9)
  assert.deepEqual(
    Array.from({ length: 9 }, (_v, i) => list.get(i).id),
    ["p0", "p1", "a-1", "p2", "p3", "p4", "b-1", "b-2", "p5"]
  )
  for (let view = 0; view < 9; view++) {
    const { at, page } = list.fromView(view)
    assert.equal(list.toView(at, page), view, `round trip of ${view}`)
  }
})

test("which stacks to ask for: once each, and not again when their pages are here", () => {
  const { list } = makeList(6, { 1: ["a", 2], 4: ["b", 3] })
  assert.deepEqual(list.wanted(0, 5), [{ id: "a", cover: "p1" }, { id: "b", cover: "p4" }])
  assert.deepEqual(list.wanted(0, 5), [])

  list.forget("a")
  assert.deepEqual(list.wanted(0, 2), [{ id: "a", cover: "p1" }])

  list.expand("a", "p1", pagesOf("p1", "a", 2))
  assert.deepEqual(list.wanted(0, 2), [])
})

test("a stack whose cover is no longer its slide is closed, and asked for again", () => {
  const { store, list } = list5()
  list.expand("s1", "p2", pagesOf("p2", "s1", 3))
  assert.equal(list.total, 7)

  // The timeline now has another photo there (the stack was taken apart, or moved away).
  store.put("2018-07-14", 2, [{ id: "p2", stack: null }])
  assert.equal(list.total, 5)
  assert.equal(list.get(3).id, "p3")

  // Its cover changed (the old one was trashed): the pages are asked for again.
  store.put("2018-07-14", 2, [{ id: "s1-1", stack: { id: "s1", count: 2, title: null } }])
  assert.deepEqual(list.wanted(0, 4), [{ id: "s1", cover: "s1-1" }])
})

test("an empty answer opens nothing", () => {
  const { list } = list5()
  list.expand("s1", "p2", [])
  assert.equal(list.total, 5)
  list.expand("s1", "p2", [{ id: "p2" }])
  assert.equal(list.total, 5)
})

test("after a new index every stack is asked for again, and stays open until the answer", () => {
  const slides = [{ id: "c", stack: { id: "S", count: 2 } }, { id: "x" }]
  const store = { total: 2, get: (i) => slides[i] || null, indexOf: (id) => slides.findIndex((s) => s.id === id) }
  const list = new StackedList(store)
  list.expand("S", "c", [{ id: "c" }, { id: "p" }])
  assert.deepEqual(list.wanted(0, 1), [], "known, and the count agrees")

  // A photo went into the stack; the kept cover slide still says 2.
  list.refreshAll()
  assert.equal(list.total, 3, "still open as it was")
  assert.deepEqual(list.wanted(0, 1), [{ id: "S", cover: "c" }])
  assert.deepEqual(list.wanted(0, 1), [], "asked once")
  list.expand("S", "c", [{ id: "c" }, { id: "p" }, { id: "x" }])
  assert.equal(list.indexOf("x"), 2, "the photo is found on its page")
  slides[0] = { id: "c", stack: { id: "S", count: 3 } } // the cover's slide, fetched again
  assert.deepEqual(list.wanted(0, 1), [])
})
