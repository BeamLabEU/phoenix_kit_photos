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
