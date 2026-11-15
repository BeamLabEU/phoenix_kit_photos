import { test } from "node:test"
import assert from "node:assert/strict"
import { moreLabel } from "../js/month_menu.js"

test("the ⋯ button names its month", () => {
  assert.equal(moreLabel("Veel: %{month}", "juuni 2026"), "Veel: juuni 2026")
  assert.equal(moreLabel(undefined, "June 2026"), "More for June 2026")
})
