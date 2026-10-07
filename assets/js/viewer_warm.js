// Warms a neighbour's ORIGINAL for core's media viewer, where it is worth it.
//
// Core's viewer warms only each neighbour's small + large (cheap, and it never
// races the picture on screen). Whether a multi-MB original is worth fetching
// ahead of an arrow press is high-end viewing: it depends on the screen, the
// line and which way the person is stepping. That decision lives here.
//
// Core announces `pk:viewer-neighbours` once the current picture has settled
// (and never on data-saver or a 2G/3G line):
//
//   detail = { prev: {original, aspect}|null, next: {original, aspect}|null,
//              direction: "prev"|"next"|"",
//              box: {width, height, dpr} }   // the viewer, CSS px + pixel ratio
//
// Policy, deliberately small:
//   - only where the `large` rung (1920 px) will not do. Tessera picks its raster
//     by the width the picture is DISPLAYED at (physical pixels, ~10% headroom),
//     and a picture is fitted inside the box: a portrait photo in a wide window
//     is narrow, so the box's width says nothing — its aspect does;
//   - only ONE original: the neighbour in the direction last stepped (next
//     before any step), not both;
//   - low fetch priority, once per URL per page (shared with core's map).
//
// Later: pick by the real display class (5K and up) and the window size, to
// load a better file than `original` when one exists. That belongs here.

export const LARGE_RUNG_PX = 1920
export const HEADROOM = 1.1

/** True on data-saver or a 2G/3G line, where no original is worth a speculative fetch. */
export function constrained(connection) {
  if (!connection) return false
  return Boolean(connection.saveData) || /(^|-)[23]g$/.test(connection.effectiveType || "")
}

/** "4 / 3" or "1.333" as a number (width / height), or null. */
export function parseAspect(aspect) {
  if (typeof aspect === "number") return aspect > 0 ? aspect : null
  const m = /^\s*([\d.]+)\s*(?:\/\s*([\d.]+))?\s*$/.exec(aspect || "")
  if (!m) return null
  const ratio = m[2] === undefined ? Number(m[1]) : Number(m[1]) / Number(m[2])
  return Number.isFinite(ratio) && ratio > 0 ? ratio : null
}

/** Physical pixels of width a picture of `aspect` lights when fitted in `box`. */
export function displayedPx(aspect, box) {
  if (!box) return 0
  const width = box.width || 0
  const height = box.height || 0
  const ratio = parseAspect(aspect)
  // A picture is fitted inside the box. Unknown shape: assume it spans the width.
  const css = ratio && height > 0 ? Math.min(width, height * ratio) : width
  return css * (box.dpr || 1)
}

/** The originals to warm for one announcement: [] or a single URL. */
export function originalsToWarm(detail, connection) {
  if (!detail || constrained(connection)) return []
  const side = detail.direction === "prev" ? detail.prev : detail.next
  if (!side || typeof side.original !== "string" || side.original === "") return []
  if (!(displayedPx(side.aspect, detail.box) > LARGE_RUNG_PX * HEADROOM)) return []
  return [side.original]
}

/** Listens on `win` for core's announcement. Returns the listener, for tests. */
export function installViewerWarm(win, ImageCtor) {
  if (!win || typeof win.addEventListener !== "function") return null
  const Img = ImageCtor || win.Image
  const listener = (e) => {
    const connection = win.navigator && win.navigator.connection
    win.__pkWarmedUrls = win.__pkWarmedUrls || {}
    for (const url of originalsToWarm(e && e.detail, connection)) {
      if (win.__pkWarmedUrls[url]) continue
      win.__pkWarmedUrls[url] = true
      const im = new Img()
      try {
        im.fetchPriority = "low"
      } catch (_e) {
        // older browsers
      }
      im.src = url
    }
  }
  win.addEventListener("pk:viewer-neighbours", listener)
  return listener
}
