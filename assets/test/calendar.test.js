import { test } from "node:test"
import assert from "node:assert/strict"
import { weekLocale, weekStartFor, weekdayNames } from "../js/calendar.js"

test("the week follows the browser's region when it speaks the page's language", () => {
  assert.equal(weekLocale("en", ["en-GB", "et"]), "en-GB")
  assert.equal(weekLocale("et", ["en-GB", "et-EE"]), "et-EE")
  assert.equal(weekLocale("et", ["en-US"]), "et")
  assert.equal(weekLocale("", []), "en")
})

test("the first day of the week is the locale's", () => {
  assert.equal(weekStartFor("en-US"), 0)
  assert.equal(weekStartFor("en-GB"), 1)
  assert.equal(weekStartFor("et"), 1)
  assert.equal(weekStartFor("not a tag!"), 1)
})

test("weekday names start where the week does", () => {
  assert.deepEqual(weekdayNames("en", 1, false).slice(0, 2), ["Mon", "Tue"])
  assert.deepEqual(weekdayNames("en", 0, false)[0], "Sun")
  assert.equal(weekdayNames("en", 1, true)[0], "M")
})
