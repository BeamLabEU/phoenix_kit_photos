import test from "node:test"
import assert from "node:assert/strict"
import { inPanel, typing } from "../js/info_panel.js"

globalThis.document = globalThis.document || { body: {} }

// A stand-in for an element: `closest(selector)` answers from the classes and attributes of
// the element and its ancestors, listed innermost first.
function element(chain, extra = {}) {
  return {
    ...extra,
    closest(selector) {
      return chain.find(({ classes = [], attrs = [] }) =>
        selector.startsWith(".") ? classes.includes(selector.slice(1)) : attrs.includes(selector.slice(1, -1))
      ) || null
    }
  }
}

const root = { classes: ["phoenix-kit-photo-timeline"], attrs: ["data-info-panel"] }
const panel = { classes: ["pk-info-panel"], attrs: ["data-info-panel"] }

test("a tile is not in the info panel, though the timeline's root names the panel", () => {
  // The click that opens the viewer leaves the tile focused; its keys are the viewer's.
  const tile = element([{ classes: ["pkt-tile"] }, root], { tagName: "BUTTON" })
  assert.equal(inPanel(tile), false)
  assert.equal(typing(tile), false)
})

test("a field or a button of the panel is in it", () => {
  assert.equal(inPanel(element([{ classes: ["btn"] }, panel])), true)
  assert.equal(inPanel(element([panel])), true)
  assert.equal(inPanel(null), false)
})
