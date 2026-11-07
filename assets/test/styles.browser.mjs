// Every style in a real browser: tiles stay on the page and apart, the page's height is what the
// layout says, a change of style keeps the middle photo in place and ends with nothing left over.
// SHOTS=<dir> also saves a picture of each style, and of the middle of a change.
import { createServer } from "node:http"
import { readFile, mkdir } from "node:fs/promises"
import { fileURLToPath } from "node:url"
import assert from "node:assert/strict"
const { chromium } = await import(process.env.PLAYWRIGHT_MODULE || "playwright")
const root = fileURLToPath(new URL("../", import.meta.url))
const shots = process.env.SHOTS
if (shots) await mkdir(shots, { recursive: true })
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
const STYLES = ["grid", "rows", "columns", "mosaic", "whole", "feed", "prints", "film", "honeycomb", "details"]
try {
  for (const [name, viewport] of [["desktop", { width: 1280, height: 800 }], ["phone", { width: 390, height: 780 }]]) {
    const page = await browser.newPage({ viewport })
    const errors = []
    page.on("pageerror", error => errors.push(error.message))
    await page.goto(`http://127.0.0.1:${server.address().port}`)
    await page.waitForFunction(() => window.hook?.pool.size > 1)

    for (const style of STYLES) {
      const before = await page.evaluate(() => {
        const id = hook.itemAtPoint(hook.el.clientWidth / 2, hook.el.clientHeight / 2)
        return { id, middle: id && hook.tileMiddle(id) - hook.el.scrollTop }
      })
      await page.evaluate(id => hook.setStyle(id), style)
      await page.waitForFunction(id => hook.styleId === id, style)
      if (shots && name === "desktop") {
        await page.waitForTimeout(190)
        await page.screenshot({ path: `${shots}/${name}-${style}-mid.png` })
      }
      await page.waitForTimeout(760)
      const after = await page.evaluate(({ focus }) => {
        const tiles = [...hook.pool].filter(([key]) => !key.startsWith("header:")).map(([, node]) => ({
          x: parseFloat(node.style.left), y: parseFloat(node.style.top),
          w: parseFloat(node.style.width), h: parseFloat(node.style.height)
        }))
        return {
          tiles,
          width: hook.el.clientWidth,
          spacer: parseFloat(hook.spacer.style.height),
          total: hook.offsets[hook.offsets.length - 1],
          nodes: hook.layer.childElementCount,
          pool: hook.pool.size,
          running: document.getAnimations().filter(a => a.playState === "running").length,
          middle: focus && hook.tileMiddle(focus) - hook.el.scrollTop,
          top: hook.el.scrollTop
        }
      }, { focus: before.id })
      assert(after.tiles.length > 0, `${style}: tiles on screen`)
      assert(Math.abs(after.spacer - after.total) < 1, `${style}: the page is as tall as the layout says`)
      assert.equal(after.nodes, after.pool + 0, `${style}: nothing left behind by the change`)
      assert.equal(after.running, 0, `${style}: every animation ended`)
      for (const t of after.tiles) {
        assert(t.x >= -0.5 && t.x + t.w <= after.width + 0.5, `${style}: a tile leaves the page: ${JSON.stringify(t)} of ${after.width}`)
        assert(t.w > 0 && t.h > 0, `${style}: an empty tile`)
      }
      if (style !== "prints") {
        const sorted = [...after.tiles].sort((a, b) => a.y - b.y)
        for (let i = 0; i < sorted.length; i++) {
          for (let j = i + 1; j < sorted.length && sorted[j].y < sorted[i].y + sorted[i].h; j++) {
            const a = sorted[i], b = sorted[j]
            const overlap = Math.min(a.x + a.w, b.x + b.w) - Math.max(a.x, b.x)
            const tall = Math.min(a.y + a.h, b.y + b.h) - Math.max(a.y, b.y)
            // Circles of a comb overlap as squares, not as circles.
            if (style !== "honeycomb") assert(overlap < 1 || tall < 1, `${style}: tiles overlap ${JSON.stringify([a, b])}`)
          }
        }
      }
      if (before.id && after.top > 0) {
        assert(Math.abs(after.middle - before.middle) < 2, `${style}: the middle photo moved from ${before.middle} to ${after.middle}`)
      }
      // A finished change leaves no animation in force over the tiles' own places.
      const held = await page.evaluate(() => {
        const node = [...hook.pool].find(([key]) => !key.startsWith("header:"))[1]
        const was = node.style.left
        node.style.left = "7px"
        const seen = getComputedStyle(node).left
        node.style.left = was
        return seen
      })
      assert.equal(held, "7px", `${style}: an animation still holds the tiles`)
      if (shots) await page.screenshot({ path: `${shots}/${name}-${style}.png` })

      // A jump lands on the month's first row, wherever the style put it.
      const landed = await page.evaluate(() => {
        hook.jumpTo(sections[3].id)
        return hook.el.scrollTop + hook.inset - hook.offsets[3]
      })
      assert(Math.abs(landed) < 1, `${style}: jump to a month`)
      await page.evaluate(() => hook.jumpTo(sections[6].id))
      await page.waitForTimeout(30)
    }

    assert.equal(await page.evaluate(() => counts.aspects), 1, "the ratios are asked for once")
    assert.deepEqual(errors, [])
    await page.close()
  }
  console.log("styles ok")
} finally {
  await browser.close()
  server.close()
}
