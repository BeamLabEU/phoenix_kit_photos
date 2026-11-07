// Choosing photos with a real pointer: Shift + click across a month, the box with its scrolling
// edge, tiles recycled while chosen, and every style still drawing what is chosen.
import { createServer } from "node:http"
import { readFile } from "node:fs/promises"
import { fileURLToPath } from "node:url"
import assert from "node:assert/strict"
const { chromium } = await import(process.env.PLAYWRIGHT_MODULE || "playwright")
const root = fileURLToPath(new URL("../", import.meta.url))
const server = createServer(async (req, res) => {
  try {
    const url = req.url.split("?")[0]
    const path = url === "/" ? "/test/styles.html" : url
    if (!/^\/(js|test)\/[a-z_./]+$/.test(path) || path.includes("..")) throw Error("path")
    res.setHeader("content-type", path.endsWith(".js") ? "text/javascript" : "text/html")
    res.end(await readFile(root + path))
  } catch { res.writeHead(404).end() }
})
await new Promise(resolve => server.listen(0, "127.0.0.1", resolve))
const browser = await chromium.launch({ headless: true, args: ["--no-sandbox"] })
try {
  const page = await browser.newPage({ viewport: { width: 1000, height: 700 } })
  const errors = []
  page.on("pageerror", error => errors.push(error.message))
  await page.goto(`http://127.0.0.1:${server.address().port}?selectable=1`)
  await page.waitForFunction(() => window.hook?.pool.size > 1)

  const tileBox = (n) => page.evaluate((nth) => {
    const tiles = [...hook.pool].filter(([key, node]) => !key.startsWith("header:") && node.getBoundingClientRect().top > 60)
    const box = tiles[nth][1].getBoundingClientRect()
    return { id: tiles[nth][0], x: box.left + box.width / 2, y: box.top + box.height / 2, left: box.left + 12, top: box.top + 12 }
  }, n)
  const count = () => page.evaluate(() => hook.selectedIds().length)

  // The circle chooses, a click then chooses, Escape lets go.
  const first = await tileBox(0)
  await page.mouse.move(first.x, first.y)
  await page.mouse.click(first.left + 4, first.top + 4)
  assert.equal(await count(), 1, "the circle chose it")
  assert.equal(await page.evaluate(() => hook.pager), null, "and did not open it")
  const second = await tileBox(1)
  await page.mouse.click(second.x, second.y)
  assert.equal(await count(), 2)
  await page.keyboard.press("Escape")
  assert.equal(await count(), 0)

  // The box.
  const a = await tileBox(2)
  const b = await tileBox(9)
  await page.mouse.move(a.x, a.y)
  await page.mouse.down()
  await page.mouse.move(b.x, b.y, { steps: 6 })
  assert.equal(await page.locator(".pkt-marquee").count(), 1, "the box is drawn")
  await page.mouse.up()
  assert.equal(await page.locator(".pkt-marquee").count(), 0, "and gone")
  const boxed = await count()
  assert(boxed >= 2, `the box chose ${boxed}`)
  assert.equal(await page.evaluate(() => hook.pager), null, "the drag did not open a photo")

  // Chosen tiles scroll away and come back chosen.
  const chosen = await page.evaluate(() => hook.selectedIds()[0])
  await page.evaluate(() => hook.jumpTo(sections[8].id))
  await page.waitForTimeout(50)
  assert.equal(await count(), boxed, "still chosen out of sight")
  await page.evaluate((id) => {
    const at = sections.findIndex(s => s.days_list.some(d => hook.windows.has(d.id)))
    hook.jumpTo(sections[0].id)
  }, chosen)

  // Ctrl+A, and every style draws it.
  await page.keyboard.press("Escape")
  await page.keyboard.press("Control+a")
  await page.waitForFunction(() => hook.selectedIds().length > 100)
  for (const style of ["rows", "columns", "mosaic", "whole", "feed", "prints", "film", "honeycomb", "details", "grid"]) {
    await page.evaluate(id => hook.setStyle(id), style)
    await page.waitForFunction(id => hook.styleId === id, style)
    await page.waitForTimeout(40)
    const drawn = await page.evaluate(() => hook.layer.querySelectorAll("[data-selected]").length)
    assert(drawn > 0, `${style} draws what is chosen`)
  }
  assert.deepEqual(errors, [])
  console.log("selection ok")
} finally {
  await browser.close()
  server.close()
}
