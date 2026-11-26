import { test } from "node:test"
import assert from "node:assert/strict"
import { readFileSync, readdirSync } from "node:fs"
import { join, dirname } from "node:path"
import { fileURLToPath } from "node:url"
import { adoptStyle } from "../js/csp.js"
import { addStyle } from "../js/viewer/video.js"

// The bundle works under a host Content-Security-Policy that allows inline styles by nonce
// only: every `<style>` it creates takes the page's nonce from core (`adoptStyle`) before it
// joins the document.

function withGlobals(values, t) {
  const previous = {}
  for (const [name, value] of Object.entries(values)) {
    previous[name] = Object.getOwnPropertyDescriptor(globalThis, name)
    Object.defineProperty(globalThis, name, { value, configurable: true, writable: true })
  }
  t.after(() => {
    for (const [name, descriptor] of Object.entries(previous)) {
      if (descriptor) Object.defineProperty(globalThis, name, descriptor)
      else delete globalThis[name]
    }
  })
}

test("adoptStyle hands the element to core's adoptStyle", (t) => {
  withGlobals({ window: { PhoenixKitInternals: { adoptStyle: (el) => { el.nonce = "n1" } } } }, t)
  const el = {}
  assert.equal(adoptStyle(el), el)
  assert.equal(el.nonce, "n1")
})

test("adoptStyle leaves the element alone on a core without the function", (t) => {
  const window = {}
  withGlobals({ window }, t)
  for (const internals of [undefined, {}, { adoptStyle: "no" }]) {
    window.PhoenixKitInternals = internals
    const el = {}
    assert.equal(adoptStyle(el), el)
    assert.deepEqual(el, {})
  }
})

test("adoptStyle works where there is no window", () => {
  assert.equal(typeof window, "undefined")
  const el = {}
  assert.equal(adoptStyle(el), el)
})

test("a style added to the page has its nonce before it is inserted", (t) => {
  const appended = []
  withGlobals({
    window: { PhoenixKitInternals: { adoptStyle: (el) => { el.nonce = "n2" } } },
    document: {
      getElementById: () => null,
      createElement: (tag) => ({ tag }),
      // The nonce the element has at this moment is the one the browser checks.
      head: { appendChild: (el) => appended.push({ ...el }) },
    },
  }, t)
  addStyle("pk-test-css", ".a{color:red}")
  assert.deepEqual(appended, [{ tag: "style", nonce: "n2", id: "pk-test-css", textContent: ".a{color:red}" }])
})

const JS = join(dirname(fileURLToPath(import.meta.url)), "..", "js")

function sources(dir = JS) {
  return readdirSync(dir, { withFileTypes: true }).flatMap((entry) =>
    entry.isDirectory() ? sources(join(dir, entry.name)) : entry.name.endsWith(".js") ? [join(dir, entry.name)] : [])
}

function codeLines(path) {
  return readFileSync(path, "utf8").split("\n")
    .map((line, index) => ({ line, at: `${path.slice(JS.length + 1)}:${index + 1}` }))
    .filter(({ line }) => !/^\s*(\/\/|\*|\/\*)/.test(line))
}

test("every <style> the sources create is stamped, and no <script> is created", () => {
  const offenders = []
  let created = 0
  for (const path of sources()) {
    for (const { line, at } of codeLines(path)) {
      if (/createElement\(\s*["'`]style["'`]\s*\)/.test(line)) {
        created += 1
        if (!/adoptStyle\(document\.createElement\("style"\)\)/.test(line)) offenders.push(`${at} unstamped <style>`)
      }
      if (/createElement\(\s*["'`]script["'`]\s*\)/.test(line)) offenders.push(`${at} creates a <script>`)
      if (/["'`]<\s*(?:style|script)\b/i.test(line)) offenders.push(`${at} a <style>/<script> written as a string`)
      if (/\beval\(|new Function\(/.test(line)) offenders.push(`${at} evaluates a string`)
    }
  }
  assert.deepEqual(offenders, [])
  // video.js (the engines and the map), info_panel.js, stack_strip.js, timeline_css.js.
  assert.equal(created, 4)
})

test("the sources build no markup with an inline event handler", () => {
  const offenders = []
  for (const path of sources()) {
    for (const { line, at } of codeLines(path)) {
      if (/[\s"'`<]on[a-z]+\s*=\s*\\?["'`]/.test(line) || /javascript:/i.test(line)) offenders.push(at)
    }
  }
  assert.deepEqual(offenders, [])
})
