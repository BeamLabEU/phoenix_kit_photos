import { test } from "node:test"
import assert from "node:assert/strict"

import { fit, isVideo, makePreview } from "../js/upload_previews.js"

test("fit scales the shorter side to the tile's size and never enlarges", () => {
  assert.deepEqual(fit(4000, 3000, 256), { width: 341, height: 256 })
  assert.deepEqual(fit(3000, 4000, 256), { width: 256, height: 341 })
  assert.deepEqual(fit(100, 50, 256), { width: 100, height: 50 })
  assert.equal(fit(0, 50, 256), null)
})

test("a video is told by its type, or by its name when the browser gave none", () => {
  assert.equal(isVideo({ type: "video/quicktime", name: "a.mov" }), true)
  assert.equal(isVideo({ type: "image/jpeg", name: "a.mov" }), false)
  assert.equal(isVideo({ type: "", name: "clip.MOV" }), true)
  assert.equal(isVideo({ type: "", name: "IMG_1.HEIC" }), false)
})

test("no picture, and no throw, where there is no browser or the file cannot be read", async () => {
  assert.equal(await makePreview({ type: "image/jpeg" }, {}), null)

  const env = {
    document: { createElement: () => ({}) },
    URL: { createObjectURL: () => "blob:x", revokeObjectURL() {} },
    createImageBitmap: () => Promise.reject(new Error("cannot decode"))
  }
  assert.equal(await makePreview({ type: "image/heic", name: "a.heic" }, env), null)
})

test("a photo is drawn small and comes back as an object URL", async () => {
  const drawn = []
  const canvas = {
    getContext: () => ({ drawImage: (...args) => drawn.push(args.slice(1)) }),
    toBlob: done => done({ size: 1 })
  }
  let closed = false
  const env = {
    document: { createElement: () => canvas },
    URL: { createObjectURL: () => "blob:small", revokeObjectURL() {} },
    createImageBitmap: (_file, options) => {
      assert.equal(options.resizeHeight, 256)
      return Promise.resolve({ width: 341, height: 256, close: () => (closed = true) })
    }
  }

  assert.equal(await makePreview({ type: "image/jpeg", name: "a.jpg" }, env), "blob:small")
  assert.deepEqual(drawn, [[0, 0, 341, 256]])
  assert.equal(closed, true)
})
