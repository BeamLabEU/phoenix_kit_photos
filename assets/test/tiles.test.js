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
