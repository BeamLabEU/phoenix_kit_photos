// Synthetic hook/DOM regression; not the full Chrome + Safari host acceptance gate.
import { createServer } from "node:http"
import { readFile } from "node:fs/promises"
import { fileURLToPath } from "node:url"
import assert from "node:assert/strict"
const { chromium } = await import(process.env.PLAYWRIGHT_MODULE || "playwright")
const root = fileURLToPath(new URL("../", import.meta.url))
const server = createServer(async (req, res) => {
  try {
    const path = req.url === "/" ? "/test/browser.html" : req.url
    if (!/^\/(js|test)\/[a-z_./]+$/.test(path) || path.includes("..")) throw Error("path")
    res.setHeader("content-type", path.endsWith(".js") ? "text/javascript" : "text/html")
    res.end(await readFile(root + path))
  } catch { res.writeHead(404).end() }
})
await new Promise(resolve => server.listen(0, "127.0.0.1", resolve))
const browser = await chromium.launch({ headless: true, args: ["--no-sandbox"] })
try {
  const page = await browser.newPage({ viewport: { width: 1200, height: 800 } })
  const errors = []
  page.on("pageerror", error => errors.push(error.message))
  await page.goto(`http://127.0.0.1:${server.address().port}`)
  await page.waitForFunction(() => window.hook?.pool.size > 1)
  const result = await page.evaluate(async () => {
    const frame = () => new Promise(resolve => requestAnimationFrame(resolve))
    let maxNodes = 0, maxCachedWindows = 0, maxJumpMs = 0
    for (let i = 0; i < 100; i++) {
      const start = performance.now()
      hook.jumpTo(sections[(i * 37) % sections.length].id)
      await frame()
      maxJumpMs = Math.max(maxJumpMs, performance.now() - start)
      maxNodes = Math.max(maxNodes, hook.el.querySelectorAll("button").length)
      maxCachedWindows = Math.max(maxCachedWindows, hook.windows.size)
    }
    hook.jumpTo(sections[0].id)
    hook.el.scrollTop = 40 + Math.floor(1100 / 5) * (hook.metrics.cell + hook.metrics.gap)
    hook.handleScroll()
    await frame()
    const tailVisible = hook.pool.has("photo-1100")
    hook.setIndex({ library: "other", revision: 2, sections: [{ id: "other", label: "Other", count: 1, days_list: [{ id: "new-day", count: 1 }] }] })
    await frame()
    hook.setWindow({ section: "new-day", revision: 1, items: [{ id: "stale" }] })
    return { maxNodes, maxCachedWindows, maxJumpMs, tailVisible, staleIgnored: !hook.pool.has("stale"), total: 10000 }
  })
  assert(result.maxNodes < 100, JSON.stringify(result))
  assert(result.maxCachedWindows < 12, JSON.stringify(result))
  assert(result.tailVisible, "items past the first 500 must render")
  assert(result.staleIgnored)
  assert.deepEqual(errors, [])
  console.log(JSON.stringify({ browser: await browser.version(), ...result }, null, 2))
} finally { await browser.close(); server.close() }
