// Exercise durable bookmarks by closing and reopening a browser with the same profile.
import assert from "node:assert/strict"
import { mkdtemp, rm } from "node:fs/promises"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { fileURLToPath } from "node:url"
const { chromium } = await import(process.env.PLAYWRIGHT_MODULE || "playwright")
const profile = await mkdtemp(join(tmpdir(), "photo-bookmark-reopen-"))
const bundle = fileURLToPath(new URL("../../priv/static/assets/phoenix_kit_photos.js", import.meta.url))
let context
async function open() {
  context = await chromium.launchPersistentContext(profile, {
    args: ["--no-sandbox"], viewport: { width: 1280, height: 900 }
  })
  await context.route("http://bookmark.test/**", route => route.fulfill({
    contentType: "text/html",
    body: '<div class="phoenix-kit-photo-timeline" style="--photo-timeline-inset-top:56px"><div id="grid" data-timeline-id="test" data-target="1" data-cell="170" style="position:fixed;inset:0;overflow-y:auto"><div class="phoenix-kit-photo-timeline__spacer"></div><div class="phoenix-kit-photo-timeline__layer" style="position:absolute;top:0;left:0;right:0"></div></div></div>'
  }))
  const page = await context.newPage()
  await page.goto("http://bookmark.test")
  await page.addScriptTag({ path: bundle })
  await page.evaluate(() => {
    window.h = Object.assign({}, window.PhoenixKitPhotosHooks.PhotoTimeline, {
      el: document.querySelector("#grid"), pushEventTo() {}, handleEvent() {}
    })
    h.mounted()
    h.setIndex({ library: "a", revision: 1, sections: [
      { id: "2020-01", count: 1000, days_list: [] }
    ] })
  })
  await page.waitForTimeout(200)
  return page
}
try {
  let page = await open()
  await page.mouse.move(400, 300)
  await page.mouse.wheel(0, -100000)
  await page.waitForTimeout(300)
  await page.mouse.wheel(0, 2345)
  await page.waitForTimeout(300)
  const saved = await page.evaluate(() => ({ top: h.el.scrollTop, marker: h.bookmarkTop() }))
  assert(saved.top > 1000)
  await context.close()
  context = null
  page = await open()
  assert.equal(await page.evaluate(() => sessionStorage.getItem(h.positionKey())), null,
    "reopened browser must exercise the durable fallback, not a surviving tab bookmark")
  assert.deepEqual(await page.evaluate(() => ({ top: h.el.scrollTop, marker: h.bookmarkTop() })), saved)
  console.log("PASS: closing and reopening the browser preserves position and marker without sessionStorage")
} finally {
  if (context) await context.close()
  await rm(profile, { recursive: true, force: true })
}
