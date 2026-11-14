import { test } from "node:test"
import assert from "node:assert/strict"
import { bannerKey, chapterName, chipsKey, colorClass, drawBanner, drawChips } from "../js/chapters.js"
import { buildLayout } from "../js/layouts.js"

// Just enough of a document: elements with children, classes, text, attributes and listeners.
function element(tag) {
  const node = {
    tagName: tag.toUpperCase(),
    children: [],
    dataset: {},
    attributes: {},
    listeners: {},
    className: "",
    textContent: "",
    innerHTML: "",
    append(...kids) { this.children.push(...kids) },
    replaceChildren() { this.children = [] },
    insertBefore(kid, before) {
      const at = before ? this.children.indexOf(before) : -1
      if (at < 0) this.children.push(kid)
      else this.children.splice(at, 0, kid)
    },
    remove() { this.removed = true },
    setAttribute(name, value) { this.attributes[name] = value },
    addEventListener(type, fn) { this.listeners[type] = fn },
    querySelector() { return null },
    querySelectorAll(selector) {
      const cls = selector.replace(/^\./, "")
      const found = []
      const walk = (n) => n.children.forEach(c => { if (!c.removed && String(c.className).split(" ").includes(cls)) found.push(c); walk(c) })
      walk(this)
      return found
    }
  }
  return node
}

function find(node, cls) {
  if (String(node.className).split(" ").includes(cls)) return node
  for (const kid of node.children) {
    const hit = find(kid, cls)
    if (hit) return hit
  }
  return null
}

function withDocument(fn) {
  globalThis.document = { createElement: element }
  try { return fn() } finally { delete globalThis.document }
}

const trip = {
  id: "t", title: "Trip to France", emoji: "✈️", color: "rose", dates: "12–20 July 2026",
  count_text: "248 photos", description: "Paris, then the south", cover: "/thumb.jpg", sub: false
}

test("a colour is a class from the list, never what was sent", () => {
  assert.equal(colorClass("rose"), "pkt-chapter--rose")
  assert.equal(colorClass("red;background:url(x)"), "pkt-chapter--sky")
  assert.equal(colorClass(undefined), "pkt-chapter--sky")
})

test("a chapter's name is its emoji and title", () => {
  assert.equal(chapterName(trip), "✈️ Trip to France")
  assert.equal(chapterName({ title: "Moved" }), "Moved")
})

test("the banner: kicker, title, dates with the count, description, cover, pencil", () => {
  withDocument(() => {
    const node = element("div")
    const edits = []
    drawBanner(node, { chapter: trip }, { strings: { chapter: "Chapter", edit: "Edit chapter" }, onEdit: id => edits.push(id) })
    assert.match(node.className, /pkt-banner-host pkt-chapter--rose/)
    assert.equal(find(node, "pkt-banner-kicker").textContent, "Chapter")
    assert.equal(find(node, "pkt-banner-title").textContent, "Trip to France")
    assert.equal(find(node, "pkt-banner-meta").textContent, "12–20 July 2026 · 248 photos")
    assert.equal(find(node, "pkt-banner-desc").textContent, "Paris, then the south")
    const cover = find(node, "pkt-banner-cover")
    assert.ok(cover.children.some(c => c.tagName === "IMG" && c.src === "/thumb.jpg"))
    assert.ok(find(node, "pkt-banner-edit"))
    find(node, "pkt-banner").listeners.click({ stopPropagation() {} })
    assert.deepEqual(edits, ["t"])
  })
})

test("a reader who may not change chapters gets no pencil; a sub-chapter names its chapter", () => {
  withDocument(() => {
    const node = element("div")
    const paris = { id: "p", title: "<b>Paris</b>", sub: true, parent: { title: "Trip to France", emoji: "✈️" }, dates: "12–15 July 2026" }
    drawBanner(node, { chapter: paris }, { strings: { sub: "Part of %{chapter}" } })
    assert.match(node.className, /pkt-banner--sub/)
    assert.equal(find(node, "pkt-banner-kicker").textContent, "Part of ✈️ Trip to France")
    // Typed text is text.
    assert.equal(find(node, "pkt-banner-title").textContent, "<b>Paris</b>")
    assert.equal(find(node, "pkt-banner-edit"), null)
    assert.equal(find(node, "pkt-banner").dataset.chapterEdit, undefined)
  })
})

test("chips: the chapters a month is inside, and the one just ended", () => {
  withDocument(() => {
    const node = element("div")
    const jumps = []
    const section = { within: [{ id: "t", title: "Trip", color: "amber" }], after: { id: "p", title: "Paris", emoji: "🗼" } }
    drawChips(node, section, { strings: { after: "after %{chapter}" }, onJump: id => jumps.push(id) })
    const chips = node.querySelectorAll(".pkt-chip")
    assert.deepEqual(chips.map(c => c.textContent), ["Trip", "after 🗼 Paris"])
    assert.match(chips[1].className, /pkt-chip--after/)
    chips[1].listeners.click({ stopPropagation() {} })
    assert.deepEqual(jumps, ["p"])
    // Drawn again, the old ones go.
    drawChips(node, { within: [] })
    assert.equal(node.querySelectorAll(".pkt-chip").length, 0)
  })
})

test("a banner and chips are drawn again only when what they show changed", () => {
  const section = { chapter: trip }
  assert.equal(bannerKey(section, true), bannerKey({ chapter: { ...trip } }, true))
  assert.notEqual(bannerKey(section, true), bannerKey({ chapter: { ...trip, title: "x" } }, true))
  assert.notEqual(bannerKey(section, true), bannerKey(section, false))
  assert.notEqual(chipsKey({ within: [] }), chipsKey({ within: [{ id: "t" }] }))
})

test("the calendar draws only the weeks of a month's part", () => {
  // July 2026 starts on a Wednesday; with Monday first it leads by two.
  const base = { count: 3, width: 700, cell: 100, gap: 4, header: 40, month: "2026-07", weekStart: 1,
    days: [{ id: "2026-07-12", count: 1 }, { id: "2026-07-14", count: 2 }], aspectAt: () => 1 }
  const whole = buildLayout("calendar", base)
  const part = buildLayout("calendar", { ...base, span: [12, 20] })
  assert.deepEqual(part.calendar.cells.map(c => c.day), [12, 13, 14, 15, 16, 17, 18, 19, 20])
  assert.equal(whole.calendar.cells.length, 31)
  // 12 July is a Sunday: its week is the first row of the part, and 13 July starts the next.
  assert.equal(part.calendar.cells[0].y, 40 + 26)
  assert.ok(part.height < whole.height)
  // A span of the whole month is the whole month.
  assert.equal(buildLayout("calendar", { ...base, span: [1, 31] }).calendar.cells.length, 31)
})

test("a section with a taller header lays its tiles out under it", () => {
  const grid = buildLayout("grid", { count: 4, columns: 2, width: 404, cell: 200, gap: 4, header: 132 })
  assert.equal(grid.rect(0).y, 132)
  assert.equal(grid.height, 132 + 2 * 200 + 4)
  assert.equal(buildLayout("grid", { count: 0, columns: 2, width: 404, cell: 200, gap: 4, header: 132 }).height, 132)
})
