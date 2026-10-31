import { test } from "node:test"
import assert from "node:assert/strict"

import { PhotoUploader } from "../js/photo_uploader.js"

// The hook's browser/LiveView surface is small: `el.dataset`, `window.localStorage`,
// `uploadTo`, `pushEventTo`. These fakes cover exactly that, so the concurrency logic
// is tested without a browser.
const KEY = "phoenix_kit_photos:upload_concurrency"

const localStorageFake = (initial = {}) => {
  const store = { ...initial }
  return {
    getItem: k => (k in store ? store[k] : null),
    setItem: (k, v) => {
      store[k] = String(v)
    }
  }
}

const makeHook = ({ dataset = {}, saved = undefined } = {}) => {
  const storage = localStorageFake(saved === undefined ? {} : { [KEY]: saved })
  globalThis.window = { localStorage: storage }
  const hook = Object.create(PhotoUploader)
  hook.el = {
    dataset: { concurrency: "4", concurrencyMax: "8", batch: "100", ...dataset },
    addEventListener() {},
    removeEventListener() {},
    querySelector: () => null
  }
  hook.batch = parseInt(hook.el.dataset.batch, 10)
  hook.maxConcurrency = parseInt(hook.el.dataset.concurrencyMax, 10)
  hook.concurrency = hook.readConcurrency()
  hook.gated = hook.el.dataset.auto === "false"
  hook.started = !hook.gated
  hook.queue = []
  hook.gone = false
  hook.sent = []
  hook.uploadTo = (_el, _name, files) => {
    hook.sent.push(files.length)
  }
  hook.pushEventTo = () => {}
  hook.storage = storage
  return hook
}

// A `ready` answer script: consumed one per call, the last one repeats.
const scriptReady = (hook, answers) => {
  let at = 0
  hook.ready = () => {
    const answer = answers[Math.min(at, answers.length - 1)]
    at += 1
    return Promise.resolve(answer)
  }
}

test("the concurrency control defaults to the server's data attribute", () => {
  const hook = makeHook()
  assert.equal(hook.readConcurrency(), 4)
})

test("a saved choice wins, and both are clamped to [1, max]", () => {
  assert.equal(makeHook({ saved: "2" }).readConcurrency(), 2)
  assert.equal(makeHook({ saved: "99" }).readConcurrency(), 8)
  assert.equal(makeHook({ saved: "0" }).readConcurrency(), 1)
  assert.equal(makeHook({ dataset: { concurrency: "6" } }).readConcurrency(), 6)
})

test("setConcurrency clamps and remembers the choice", () => {
  const hook = makeHook()
  hook.setConcurrency("99")
  assert.equal(hook.concurrency, 8)
  assert.equal(hook.storage.getItem(KEY), "8")
  hook.setConcurrency("nope")
  assert.equal(hook.concurrency, 4)
})

test("the drain keeps at most the chosen number in flight (sliding window)", async () => {
  const hook = makeHook()
  hook.concurrency = 3
  hook.queue = Array.from({ length: 7 }, (_, i) => ({ name: `f${i}.jpg` }))
  // The server's answer after each send: full window, one slot freed, another, ...
  scriptReady(hook, [
    { idle: true, inFlight: 0 },
    { idle: false, inFlight: 3 },
    { idle: false, inFlight: 2 },
    { idle: false, inFlight: 1 },
    { idle: false, inFlight: 3 },
    { idle: false, inFlight: 2 }
  ])

  await hook.drain()

  // 3 first, then topped up as slots freed: 1, 2, 1 — never more than 3 in flight.
  assert.deepEqual(hook.sent, [3, 1, 2, 1])
  assert.equal(hook.queue.length, 0)
})

test("the window is also capped by the batch size", async () => {
  const hook = makeHook({ dataset: { batch: "5", concurrency: "4", concurrencyMax: "8" } })
  hook.batch = 5
  hook.concurrency = 8
  hook.queue = Array.from({ length: 12 }, (_, i) => ({ name: `f${i}.jpg` }))
  scriptReady(hook, [
    { idle: true, inFlight: 0 },
    { idle: false, inFlight: 5 },
    { idle: false, inFlight: 4 },
    { idle: false, inFlight: 5 },
    { idle: false, inFlight: 2 },
    { idle: false, inFlight: 2 }
  ])

  await hook.drain()

  // The control says 8, but the batch holds 5: never more than 5 entries at once.
  assert.deepEqual(hook.sent, [5, 1, 3, 3])
  assert.ok(hook.sent.every(n => n <= 5))
  assert.equal(hook.queue.length, 0)
})

test("picker files go through the same queue as drops, and waiting carries names", async () => {
  const hook = makeHook()
  const events = []
  hook.pushEventTo = (_el, name, payload) => events.push([name, payload])
  scriptReady(hook, [{ idle: true, inFlight: 0 }])

  await hook.takeFiles([{ name: "a.jpg" }, { name: "b.jpg" }])

  assert.deepEqual(events[0], ["dropped", { files: 2, skipped: 0, unreadable: 0, truncated: false }])
  assert.deepEqual(hook.sent, [2])
  assert.equal(hook.queue.length, 0)
  // The last waiting event says nothing is left, with no names.
  assert.deepEqual(events.at(-1), ["waiting", { count: 0, names: [] }])
})

test("waiting names are capped and trimmed", () => {
  const hook = makeHook()
  hook.queue = Array.from({ length: 80 }, (_, i) => ({ name: `f${i}.jpg` }))
  const payload = hook.waitingPayload()
  assert.equal(payload.count, 80)
  assert.equal(payload.names.length, 50)
  assert.equal(payload.names[0], "f0.jpg")

  hook.queue = [{ name: "x".repeat(500) + ".jpg" }]
  assert.equal(hook.waitingPayload().names[0].length, 255)
})

test("a public library (gated) sends nothing until Upload, then feeds through the window", async () => {
  const hook = makeHook({ dataset: { auto: "false", concurrency: "2" } })
  hook.concurrency = 2
  hook.gated = true
  hook.started = false
  hook.queue = Array.from({ length: 5 }, (_, i) => ({ name: `f${i}.jpg` }))

  // The first poll happens before Upload; the submit flips `started` mid-drain.
  let polls = 0
  hook.ready = () => {
    polls += 1
    if (polls === 2) hook.started = true // the Upload click
    return Promise.resolve({ idle: false, inFlight: Math.max(0, hook.sent.reduce((a, b) => a + b, 0) - polls) })
  }

  await hook.drain()

  // Nothing was sent before the submit (first poll sent 0), and never more than 2.
  assert.ok(hook.sent.every(n => n <= 2))
  assert.equal(hook.sent.reduce((a, b) => a + b, 0), 5)
  assert.equal(hook.queue.length, 0)
})

test("the queued names are reported even while gated and nothing is sent yet", async () => {
  const hook = makeHook({ dataset: { auto: "false" } })
  hook.gated = true
  hook.started = false
  const events = []
  hook.pushEventTo = (_el, name, payload) => events.push([name, payload])
  hook.queue = [{ name: "a.jpg" }, { name: "b.jpg" }, { name: "c.jpg" }]
  scriptReady(hook, [{ idle: true, inFlight: 0 }])

  // One drain iteration's worth: the loop polls while gated, reporting the queue.
  const draining = hook.drain()
  await new Promise(resolve => setTimeout(resolve, 700))
  assert.deepEqual(hook.sent, []) // still gated: nothing sent
  const waiting = events.filter(([name]) => name === "waiting")
  assert.ok(waiting.length >= 1)
  assert.deepEqual(waiting[0][1], { count: 3, names: ["a.jpg", "b.jpg", "c.jpg"] })
  hook.queue = []
  await draining
})

test("an answer without inFlight falls back to batches, sent only when idle", async () => {
  const hook = makeHook()
  hook.queue = Array.from({ length: 150 }, (_, i) => ({ name: `f${i}.jpg` }))
  scriptReady(hook, [
    { idle: true }, // older server: no inFlight
    { idle: false },
    { idle: false },
    { idle: true },
    { idle: true }
  ])

  await hook.drain()

  assert.deepEqual(hook.sent, [100, 50])
  assert.equal(hook.queue.length, 0)
})
