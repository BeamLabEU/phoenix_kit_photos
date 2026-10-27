import { test } from "node:test"
import assert from "node:assert/strict"
import { PhotoTimeline } from "../js/photo_timeline.js"

// A hook with the page's address and history faked: what it patched, and whether it went back.
function hook({ pathname = "/anna/private", paths = true, slides = {}, pager = "off", sections = [1] } = {}) {
  const calls = { patches: [], backs: 0, opened: [], closed: 0, goTo: [] }
  const root = {
    dataset: paths
      ? { photoPath: "/anna/private/p/:code", libraryPath: "/anna/private", pager: "true" }
      : { pager: "true" }
  }
  globalThis.window = {
    location: { pathname },
    history: { back: () => calls.backs++ }
  }

  const h = Object.assign({}, PhotoTimeline, {
    el: { closest: () => root, dataset: {} },
    sections,
    slides: { get: (i) => slides[i] || null },
    js: () => ({ patch: (to, opts) => calls.patches.push([to, opts.replace]) }),
    openPager: (global) => calls.opened.push(global),
    pagerEnabled: () => true
  })

  if (pager === "open") {
    h.pager = {
      index: 0,
      close: () => calls.closed++,
      goTo: (i) => calls.goTo.push(i)
    }
  }
  return { h, calls, setPath: (p) => (window.location.pathname = p) }
}

const slides = { 0: { id: "u0", code: "aaaaaaaa" }, 1: { id: "u1", code: "bbbbbbbb" }, 2: { id: "u2" } }

test("the viewer opening adds an address, turning the page replaces it", () => {
  const { h, calls } = hook({ slides })
  h.syncAddress(0)
  h.syncAddress(1)
  assert.deepEqual(calls.patches, [
    ["/anna/private/p/aaaaaaaa", false],
    ["/anna/private/p/bbbbbbbb", true]
  ])
})

test("a photo whose address is already the page's is not patched, and counts as open", () => {
  const { h, calls } = hook({ slides, pathname: "/anna/private/p/aaaaaaaa" })
  h.syncAddress(0)
  assert.deepEqual(calls.patches, [])
  h.syncAddress(1)
  assert.deepEqual(calls.patches, [["/anna/private/p/bbbbbbbb", true]], "the next one replaces: the viewer is open")
})

test("nothing happens without the host's addresses, or for a slide with no code", () => {
  const without = hook({ slides, paths: false })
  without.h.syncAddress(0)
  assert.deepEqual(without.calls.patches, [])

  const codeless = hook({ slides })
  codeless.h.syncAddress(2)
  codeless.h.syncAddress(9)
  assert.deepEqual(codeless.calls.patches, [])
})

test("closing goes back when the viewer added the entry, else puts the library in its place", () => {
  const added = hook({ slides })
  added.h.syncAddress(0)
  added.setPath("/anna/private/p/aaaaaaaa")
  added.h.leaveAddress()
  assert.equal(added.calls.backs, 1)
  assert.deepEqual(added.calls.patches.length, 1, "no patch of its own")

  const opened = hook({ slides, pathname: "/anna/private/p/aaaaaaaa" })
  opened.h.syncAddress(0)
  opened.h.leaveAddress()
  assert.equal(opened.calls.backs, 0)
  assert.deepEqual(opened.calls.patches, [["/anna/private", true]])
})

test("closing leaves the address alone when the server closed the viewer, or the page is not at a photo", () => {
  const server = hook({ slides, pathname: "/anna/private/p/aaaaaaaa" })
  server.h.addressClosing = true
  server.h.leaveAddress()
  assert.equal(server.calls.backs + server.calls.patches.length, 0)
  assert.equal(server.h.addressClosing, false, "once")

  const elsewhere = hook({ slides, pathname: "/anna/other" })
  elsewhere.h.leaveAddress()
  assert.equal(elsewhere.calls.backs + elsewhere.calls.patches.length, 0)
})

test("an address that names no photo closes the viewer, and the close does not touch the address", () => {
  const { h, calls } = hook({ pager: "open" })
  h.applyView({ id: null, global: null })
  assert.equal(calls.closed, 1)
  assert.equal(h.addressClosing, true)
})

test("an address that names a photo opens the viewer on it, once there is an index", () => {
  const { h, calls } = hook({ sections: [] })
  h.applyView({ id: "u1", global: 41 })
  assert.deepEqual(calls.opened, [], "waits for the index")
  h.sections = [1]
  h.openFromAddress()
  assert.deepEqual(calls.opened, [41])
  assert.equal(h.addressOpen, true, "the address is already right: opening adds nothing")
  h.openFromAddress()
  assert.deepEqual(calls.opened, [41], "once")
})

test("a viewer already on the photo is left alone; on another it turns", () => {
  const same = hook({ slides, pager: "open" })
  same.h.applyView({ id: "u0", global: 0 })
  assert.deepEqual(same.calls.goTo, [])

  const other = hook({ slides, pager: "open" })
  other.h.applyView({ id: "u1", global: 1 })
  assert.deepEqual(other.calls.goTo, [1])
})

test("the echo of the viewer's own address change does not pull it back", () => {
  const { h, calls } = hook({ slides, pager: "open" })
  h.syncAddress(0)
  h.syncAddress(1)
  h.pager.index = 1
  // the server answers for the first address after the person has turned to the second
  h.applyView({ id: "u0", global: 0 })
  assert.deepEqual(calls.goTo, [])
})

test("an address change from elsewhere (Forward) opens the viewer even for a photo seen a moment ago", () => {
  const { h, calls } = hook({ slides })
  h.syncAddress(0)
  h.addressOpen = false
  h.applyView({ id: "u0", global: 0 })
  assert.deepEqual(calls.opened, [0], "no viewer open: not an echo")
})

test("without the host's addresses a view is ignored", () => {
  const { h, calls } = hook({ paths: false })
  h.applyView({ id: "u1", global: 3 })
  assert.deepEqual(calls.opened, [])
})
