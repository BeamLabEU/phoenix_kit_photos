import { test } from "node:test"
import assert from "node:assert/strict"
import { fillTile } from "../js/tiles.js"

// Just enough of a document for fillTile: elements that hold children, a class and a style.
function element(tag) {
  return {
    tagName: tag.toUpperCase(),
    children: [],
    dataset: {},
    style: { setProperty() {} },
    className: "",
    textContent: "",
    appendChild(child) { this.children.push(child); return child },
    append(...nodes) { this.children.push(...nodes) }
  }
}

function findImg(node) {
  if (node.tagName === "IMG") return node
  for (const child of node.children || []) {
    const found = findImg(child)
    if (found) return found
  }
  return null
}

test("a tile's picture loads at once: the grid only builds tiles that are on screen", () => {
  globalThis.document = { createElement: element, documentElement: { lang: "en" } }
  try {
    const node = element("button")
    fillTile(node, { id: "f1", kind: "image", taken_at: "2026-09-01T10:00:00Z", size: 1000 })
    const img = findImg(node)
    assert.ok(img, "the tile has a picture")
    // Safari leaves a lazy image in a scrolling element blank until that element scrolls.
    assert.equal(img.loading, "eager")
    assert.equal(img.decoding, "async")
  } finally {
    delete globalThis.document
  }
})

// --- a file whose sizes are still being made ---------------------------------------

test("a pending file's tile is marked, and shows only the picture offered for it", async () => {
  const { markPending, pickSource } = await import("../js/tiles.js")
  const { offerPreview, withdrawPreviews, onPreviewOffered } = await import("../js/upload_previews.js")
  const node = { dataset: {} }
  const item = { id: "file-1", pending: true, thumb: null, fit: null, preview: null, large: null }

  markPending(node, item)
  assert.equal(node.dataset.pending, "")
  assert.equal(pickSource(item, 200, 200, {}), undefined)

  const heard = []
  const stop = onPreviewOffered(id => heard.push(id))
  offerPreview("file-1", "blob:mine")
  offerPreview("file-1", "blob:mine") // told once
  assert.deepEqual(heard, ["file-1"])
  assert.equal(pickSource(item, 200, 200, {}), "blob:mine")
  stop()

  // The real picture wins as soon as the file has one.
  const ready = { ...item, pending: false, thumb: "/file/1/small_square" }
  markPending(node, ready)
  assert.equal("pending" in node.dataset, false)
  assert.equal(pickSource(ready, 200, 200, {}), "/file/1/small_square")

  withdrawPreviews("blob:mine")
  assert.equal(pickSource(item, 200, 200, {}), undefined)
})

// A tile with what markStack touches: its badge and name, its label and title.
function stackTile() {
  globalThis.document = { createElement: element, documentElement: { lang: "en" } }
  const node = element("button")
  node.attributes = {}
  node.setAttribute = (name, value) => { node.attributes[name] = value }
  node.removeAttribute = name => { delete node.attributes[name] }
  const find = (n, cls) => {
    if (n.className === cls) return n
    for (const child of n.children || []) {
      const found = find(child, cls)
      if (found) return found
    }
    return null
  }
  node.querySelector = selector => find(node, selector.replace(/^\./, ""))
  fillTile(node, { id: "f1", kind: "image", name: "page 1.jpg" })
  return node
}

test("a stack's tile wears its count and says what it is; unstacked, it is a photo again", async () => {
  const { markStack } = await import("../js/tiles.js")
  try {
    const node = stackTile()
    const item = { id: "f1", kind: "image", name: "page 1.jpg", stack: { id: "s1", count: 8, title: "Lease" } }

    markStack(node, item, "Stack of %{count} photos")
    assert.equal(node.dataset.stack, "s1")
    assert.equal(node.querySelector(".pkt-stack").textContent, "8")
    assert.equal(node.attributes["aria-label"], "Lease · Stack of 8 photos")
    assert.equal(node.title, "Lease")
    assert.equal(node.querySelector(".pkt-name").textContent, "Lease")

    // No title: the label says what it is, the name stays the photo's.
    markStack(node, { ...item, stack: { id: "s1", count: 3, title: null } }, "Stack of %{count} photos")
    assert.equal(node.attributes["aria-label"], "Stack of 3 photos")
    assert.equal(node.querySelector(".pkt-name").textContent, "page 1.jpg")

    // The same tile, reused for the photo once unstacked (or left alone in its stack).
    markStack(node, { id: "f1", kind: "image", name: "page 1.jpg", stack: null })
    assert.equal(node.dataset.stack, undefined)
    assert.equal(node.querySelector(".pkt-stack").textContent, "")
    assert.equal(node.attributes["aria-label"], "Open photo")
    assert.equal(node.attributes.title, undefined)

    // A stack of one is a photo.
    markStack(node, { ...item, stack: { id: "s1", count: 1, title: "x" } })
    assert.equal(node.dataset.stack, undefined)
  } finally {
    delete globalThis.document
  }
})
