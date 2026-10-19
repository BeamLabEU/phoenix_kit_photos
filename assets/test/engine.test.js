import test from "node:test"
import assert from "node:assert/strict"
import { DEFAULT_ENGINE, engineFor, engineIds, loadEngine, registerEngine } from "../js/viewer/engine.js"
import "../js/viewer/engines.js"

test("the engines the page ships are registered, the default among them", () => {
  assert.deepEqual(engineIds().sort(), ["photoswipe", "snap"])
  assert(engineIds().includes(DEFAULT_ENGINE))
})

test("the host's setting names an engine, the default one, or none", () => {
  assert.equal(engineFor("false"), null)
  assert.equal(engineFor(""), null)
  assert.equal(engineFor(undefined), null)
  assert.equal(engineFor(null), null)
  assert.equal(engineFor("true"), DEFAULT_ENGINE)
  assert.equal(engineFor("snap"), "snap")
  assert.equal(engineFor(" photoswipe "), "photoswipe")
})

test("a name nobody registered gets the default engine, not a broken viewer", () => {
  assert.equal(engineFor("nonsense"), DEFAULT_ENGINE)
})

test("loadEngine resolves to the registered class, and to the default for an unknown id", async () => {
  class Fake {
    static id = "fake"
  }
  class Default {
    static id = "default"
  }
  registerEngine("fake", async () => Fake)
  assert.equal(await loadEngine("fake"), Fake)
  assert.equal(engineFor("fake"), "fake")

  registerEngine(DEFAULT_ENGINE, async () => Default)
  assert.equal(await loadEngine("unknown"), Default)
})
