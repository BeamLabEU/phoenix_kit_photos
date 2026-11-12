import { test } from "node:test"
import assert from "node:assert/strict"

import { linkIn, linkFromPaste, linkFromClipboardItems, LinkFetcher, LINK_EVENT } from "../js/link_fetcher.js"

const clip = ({ text = "", files = [] } = {}) => ({
  files,
  items: [{ kind: "string", type: "text/plain" }, ...files.map(f => ({ kind: "file", type: f.type, getAsFile: () => f }))],
  getData: type => (type === "text/plain" ? text : "")
})

test("linkIn: one http(s) link, the sentence around it dropped", () => {
  assert.equal(linkIn(" https://www.flickr.com/photos/x/1 "), "https://www.flickr.com/photos/x/1")
  assert.equal(linkIn("look: https://youtu.be/abc."), "https://youtu.be/abc")
  assert.equal(linkIn("(https://example.com/a)"), "https://example.com/a")
  assert.equal(linkIn("https://en.wikipedia.org/wiki/A_(b)"), "https://en.wikipedia.org/wiki/A_(b)")
})

test("linkIn: no link, two links, other schemes", () => {
  assert.equal(linkIn("just words"), null)
  assert.equal(linkIn("https://a.com/1 https://b.com/2"), null)
  assert.equal(linkIn("ftp://example.com/a.jpg"), null)
  assert.equal(linkIn(null), null)
})

test("linkFromPaste: text with a link, but never a paste that carries files", () => {
  assert.equal(linkFromPaste(clip({ text: "https://site.example/p/1" })), "https://site.example/p/1")
  const png = new File(["x"], "a.png", { type: "image/png" })
  assert.equal(linkFromPaste(clip({ text: "https://site.example/p/1", files: [png] })), null)
  assert.equal(linkFromPaste(clip({ text: "hello" })), null)
  assert.equal(linkFromPaste(null), null)
})

test("linkFromClipboardItems: the text item's link", async () => {
  const items = [
    { types: ["image/png"], getType: async () => new Blob(["x"]) },
    { types: ["text/plain"], getType: async () => new Blob(["see https://site.example/a"]) }
  ]
  assert.equal(await linkFromClipboardItems(items), "https://site.example/a")
  assert.equal(await linkFromClipboardItems([{ types: ["text/plain"], getType: async () => new Blob(["no"]) }]), null)
  assert.equal(await linkFromClipboardItems([{ types: ["text/plain"], getType: async () => { throw new Error("denied") } }]), null)
})

test("the hook hands a pasted link to the component, and leaves fields and files alone", () => {
  const listeners = {}
  const docListeners = {}
  globalThis.window = { addEventListener: (k, f) => (listeners[k] = f), removeEventListener: () => {} }
  globalThis.document = { addEventListener: (k, f) => (docListeners[k] = f), removeEventListener: () => {} }

  const pushed = []
  const hook = Object.create(LinkFetcher)
  hook.el = {}
  hook.pushEventTo = (_el, event, payload) => pushed.push([event, payload])
  hook.mounted()

  let prevented = false
  const event = (target, data) => ({ target, clipboardData: data, defaultPrevented: false, preventDefault: () => (prevented = true) })
  const body = { closest: () => null }
  const input = { closest: () => ({ tagName: "INPUT", type: "text" }) }

  listeners.paste(event(body, clip({ text: "https://site.example/a" })))
  assert.deepEqual(pushed, [["paste_link", { text: "https://site.example/a" }]])
  assert.equal(prevented, true)

  listeners.paste(event(input, clip({ text: "https://site.example/b" })))
  listeners.paste(event(body, clip({ text: "not a link" })))
  assert.equal(pushed.length, 1)

  docListeners[LINK_EVENT]({ detail: { text: "https://site.example/c" } })
  assert.deepEqual(pushed[1], ["paste_link", { text: "https://site.example/c" }])

  delete globalThis.window
  delete globalThis.document
})
