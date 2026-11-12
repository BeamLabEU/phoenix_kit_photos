import { test } from "node:test"
import assert from "node:assert/strict"

import {
  canReadClipboard,
  carriesPastedFiles,
  filesFromClipboard,
  isEditable,
  madeUp,
  pastedName,
  filesFromPaste
} from "../js/paste_files.js"
import { PhotoUploader } from "../js/photo_uploader.js"

const ACCEPT = [".jpg", ".png", ".heic", ".mov"]
const NOW = new Date(2026, 10, 11, 14, 30, 5) // local time
const JUST_NOW = NOW.getTime() - 1_000
const LAST_YEAR = NOW.getTime() - 365 * 86_400_000

const file = (name, { type = "image/png", lastModified = LAST_YEAR, bytes = "x" } = {}) =>
  new File([bytes], name, { type, lastModified })

// The clipboard's DataTransfer: text items beside the files, as browsers give them.
const clip = (files, { text = null, entries = false } = {}) => ({
  files,
  items: [
    ...(text === null ? [] : [{ kind: "string", type: "text/plain", getAsFile: () => null }]),
    ...files.map(f => ({
      kind: "file",
      type: f.type,
      webkitGetAsEntry: entries ? () => ({ isFile: true, isDirectory: false, name: f.name, file: ok => ok(f) }) : () => null,
      getAsFile: () => f
    }))
  ]
})

// The bits of a DOM element `isEditable` reads.
const el = (tagName, { type = "", editable = false, inside = null } = {}) => {
  const self = {
    tagName,
    type,
    isContentEditable: editable,
    closest(selector) {
      const tags = selector.split(",").map(s => s.trim().split(/[\[:]/)[0].toLowerCase())
      if (tags.includes(tagName.toLowerCase())) return self
      return inside ? inside.closest(selector) : null
    }
  }
  return self
}

test("a paste of text alone carries no files; one with a file does", () => {
  assert.equal(carriesPastedFiles(null), false)
  assert.equal(carriesPastedFiles(clip([], { text: "hello" })), false)
  assert.equal(carriesPastedFiles(clip([file("a.jpg")])), true)
  assert.equal(carriesPastedFiles({ files: [], items: [{ kind: "file" }] }), true)
})

test("text fields keep their paste; a file input and the page do not", () => {
  assert.equal(isEditable(el("TEXTAREA")), true)
  assert.equal(isEditable(el("INPUT", { type: "text" })), true)
  assert.equal(isEditable(el("INPUT", { type: "search" })), true)
  assert.equal(isEditable(el("SPAN", { inside: el("TEXTAREA") })), true)
  assert.equal(isEditable(el("DIV", { editable: true })), true)
  assert.equal(isEditable(el("INPUT", { type: "file" })), false)
  assert.equal(isEditable(el("BODY")), false)
  assert.equal(isEditable(null), false)
})

test("an image the browser made up is told from a file copied from a folder", () => {
  const now = NOW.getTime()
  assert.equal(madeUp(file("image.png", { lastModified: JUST_NOW }), now), true)
  assert.equal(madeUp(file("image.jpg", { lastModified: JUST_NOW }), now), true)
  assert.equal(madeUp(file("", { lastModified: JUST_NOW }), now), true)
  // A real image.png from a folder was not modified a second ago.
  assert.equal(madeUp(file("image.png", { lastModified: LAST_YEAR }), now), false)
  assert.equal(madeUp(file("IMG_0001.HEIC", { lastModified: JUST_NOW }), now), false)
})

test("a made-up image is named for the local time of the paste, numbered after the first", () => {
  assert.equal(pastedName(file("image.png"), NOW), "Pasted_20261111_143005.png")
  assert.equal(pastedName(file("image.JPG"), NOW, 1), "Pasted_20261111_143005_2.jpg")
  assert.equal(pastedName(file("", { type: "image/jpeg" }), NOW), "Pasted_20261111_143005.jpg")
  assert.equal(pastedName(file("", { type: "" }), NOW), "Pasted_20261111_143005.png")
})

test("a screenshot paste becomes one renamed file with its bytes and type", async () => {
  const shot = file("image.png", { lastModified: JUST_NOW, bytes: "png-bytes" })
  const result = await filesFromPaste(clip([shot], { text: "" }), { accept: ACCEPT, now: NOW })
  assert.equal(result.files.length, 1)
  assert.equal(result.files[0].name, "Pasted_20261111_143005.png")
  assert.equal(result.files[0].type, "image/png")
  assert.equal(result.files[0].size, shot.size)
  assert.equal(await result.files[0].text(), "png-bytes")
})

test("several copied files all come through under their own names, unwanted kinds counted", async () => {
  const files = [file("IMG_1.HEIC"), file("IMG_2.jpg"), file("clip.mov", { type: "video/quicktime" }), file("notes.txt", { type: "text/plain" })]
  for (const entries of [false, true]) {
    const result = await filesFromPaste(clip(files, { text: "IMG_1.HEIC", entries }), { accept: ACCEPT, now: NOW })
    assert.deepEqual(result.files.map(f => f.name), ["IMG_1.HEIC", "IMG_2.jpg", "clip.mov"])
    assert.equal(result.skipped, 1)
  }
})

test("two made-up images in one paste get distinct names; real files beside them keep theirs", async () => {
  const pasted = [file("image.png", { lastModified: JUST_NOW }), file("IMG_2.jpg"), file("image.png", { lastModified: JUST_NOW })]
  const result = await filesFromPaste(clip(pasted), { accept: ACCEPT, now: NOW })
  assert.deepEqual(result.files.map(f => f.name), ["Pasted_20261111_143005.png", "IMG_2.jpg", "Pasted_20261111_143005_2.png"])
})

// The hook's paste handler, with the window's listeners captured.
const mountHook = () => {
  const listeners = {}
  globalThis.window = {
    localStorage: { getItem: () => null, setItem() {} },
    addEventListener: (name, fn) => (listeners[name] = fn),
    removeEventListener: name => delete listeners[name]
  }
  const hook = Object.create(PhotoUploader)
  hook.el = { dataset: { accept: JSON.stringify(ACCEPT) }, addEventListener() {}, removeEventListener() {}, querySelector: () => null }
  hook.taken = []
  hook.takeFiles = files => hook.taken.push(files.map(f => f.name))
  hook.mounted()
  return { hook, listeners }
}

const pasteEvent = (clipboardData, target = el("BODY")) => {
  const event = { clipboardData, target, defaultPrevented: false, preventDefault: () => (event.defaultPrevented = true) }
  return event
}

test("a paste of files on the page is taken and kept from the browser", async () => {
  const { hook, listeners } = mountHook()
  const event = pasteEvent(clip([file("IMG_1.jpg"), file("IMG_2.jpg")], { text: "IMG_1.jpg" }))
  listeners.paste(event)
  await new Promise(resolve => setTimeout(resolve, 0))
  assert.equal(event.defaultPrevented, true)
  assert.deepEqual(hook.taken, [["IMG_1.jpg", "IMG_2.jpg"]])
  hook.destroyed()
  assert.equal(listeners.paste, undefined)
})

test("a paste into a text field, or of text alone, is left to the browser", async () => {
  const { hook, listeners } = mountHook()
  const inField = pasteEvent(clip([file("IMG_1.jpg")]), el("TEXTAREA"))
  const textOnly = pasteEvent(clip([], { text: "hello" }))
  listeners.paste(inField)
  listeners.paste(textOnly)
  await new Promise(resolve => setTimeout(resolve, 0))
  assert.equal(inField.defaultPrevented, false)
  assert.equal(textOnly.defaultPrevented, false)
  assert.deepEqual(hook.taken, [])
})

// A ClipboardItem as `navigator.clipboard.read()` gives it: its types, and each as a Blob.
const clipItem = (blobs, { failing = [] } = {}) => ({
  types: Object.keys(blobs),
  getType: type => (failing.includes(type) ? Promise.reject(new Error("gone")) : Promise.resolve(blobs[type]))
})

test("the clipboard can be read on request only where clipboard.read exists", () => {
  assert.equal(canReadClipboard({ clipboard: { read: async () => [] } }), true)
  assert.equal(canReadClipboard({ clipboard: { readText: async () => "" } }), false)
  assert.equal(canReadClipboard({}), false)
  assert.equal(canReadClipboard(null), false)
})

test("each clipboard image becomes one pasted file, text items are left alone", async () => {
  const png = new Blob(["png-bytes"], { type: "image/png" })
  const jpeg = new Blob(["jpeg-bytes"], { type: "image/jpeg" })
  const items = [
    clipItem({ "text/plain": new Blob(["hi"]) }),
    clipItem({ "image/png": png, "text/html": new Blob(["<img>"]) }),
    clipItem({ "image/jpeg": jpeg })
  ]
  const result = await filesFromClipboard(items, { accept: ACCEPT, now: NOW })
  assert.deepEqual(result.files.map(f => f.name), ["Pasted_20261111_143005.png", "Pasted_20261111_143005_2.jpg"])
  assert.deepEqual(result.files.map(f => f.type), ["image/png", "image/jpeg"])
  assert.equal(await result.files[0].text(), "png-bytes")
  assert.equal(result.files[0].lastModified, NOW.getTime())
  assert.equal(result.skipped, 0)
})

test("an image of a kind not taken, or one that cannot be read, is counted; nothing at all is empty", async () => {
  const gif = new Blob(["gif"], { type: "image/gif" })
  const png = new Blob(["png"], { type: "image/png" })
  // The first type the page takes wins: the gif is passed over for the png.
  const both = await filesFromClipboard([clipItem({ "image/gif": gif, "image/png": png })], { accept: ACCEPT, now: NOW })
  assert.deepEqual(both.files.map(f => f.type), ["image/png"])

  const refused = await filesFromClipboard(
    [clipItem({ "image/gif": gif }), clipItem({ "image/png": png }, { failing: ["image/png"] })],
    { accept: ACCEPT, now: NOW }
  )
  assert.deepEqual(refused.files, [])
  assert.equal(refused.skipped, 2)

  const empty = await filesFromClipboard([clipItem({ "text/plain": new Blob(["x"]) })], { accept: ACCEPT, now: NOW })
  assert.deepEqual(empty, { files: [], skipped: 0, unreadable: 0, truncated: false })
})

// The Paste button through the hook: what it hands on, and what it tells the component.
const pasteButtonHook = () => {
  const { hook } = mountHook()
  hook.pushed = []
  hook.pushEventTo = (_el, name, payload) => hook.pushed.push([name, payload])
  return hook
}

test("the Paste button hands the clipboard's images on, or says why there were none", async () => {
  const png = new Blob(["png"], { type: "image/png" })

  const taking = pasteButtonHook()
  await taking.pasteClipboard({ clipboard: { read: async () => [clipItem({ "image/png": png })] } })
  assert.equal(taking.taken.length, 1)
  assert.match(taking.taken[0][0], /^Pasted_\d{8}_\d{6}\.png$/)
  assert.deepEqual(taking.pushed, [])

  const empty = pasteButtonHook()
  await empty.pasteClipboard({ clipboard: { read: async () => [clipItem({ "text/plain": new Blob(["x"]) })] } })
  assert.deepEqual(empty.pushed, [["clipboard", { result: "empty" }]])

  const denied = pasteButtonHook()
  const notAllowed = Object.assign(new Error("dismissed"), { name: "NotAllowedError" })
  await denied.pasteClipboard({ clipboard: { read: async () => Promise.reject(notAllowed) } })
  assert.deepEqual(denied.pushed, [["clipboard", { result: "denied" }]])

  const failed = pasteButtonHook()
  await failed.pasteClipboard({ clipboard: { read: async () => Promise.reject(new Error("odd")) } })
  assert.deepEqual(failed.pushed, [["clipboard", { result: "failed" }]])
  assert.deepEqual(failed.taken, [])
})

test("the Paste button hands a copied link to the page's link fetcher, where there is one", async () => {
  const item = clipItem({ "text/plain": new Blob(["https://site.example/p/1"]) })
  const read = { clipboard: { read: async () => [item] } }

  const dispatched = []
  const previous = globalThis.document
  globalThis.document = { dispatchEvent: event => dispatched.push(event), documentElement: { setAttribute() {} } }
  try {
    const withFetcher = pasteButtonHook()
    withFetcher.el.dataset.linkFetcher = "true"
    await withFetcher.pasteClipboard(read)
    assert.equal(dispatched.length, 1)
    assert.equal(dispatched[0].type, "phoenix-kit-photos:link")
    assert.deepEqual(dispatched[0].detail, { text: "https://site.example/p/1" })
    assert.deepEqual(withFetcher.pushed, [["close", {}]])

    // No fetcher on the page: a link is no picture, as before.
    const without = pasteButtonHook()
    await without.pasteClipboard(read)
    assert.deepEqual(without.pushed, [["clipboard", { result: "empty" }]])
    assert.equal(dispatched.length, 1)
  } finally {
    globalThis.document = previous
  }
})
