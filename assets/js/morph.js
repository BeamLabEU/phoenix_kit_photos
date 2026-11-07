// The change from one style to another. Every tile goes from where it was to where it belongs,
// in a wave spreading from the middle of the screen. Width and height are animated, not a scale,
// because `object-fit: cover` then recrops the photo at every step: a square opening up into the
// whole picture is the point of the thing. With very many tiles on screen that is too much layout
// for one frame, so they travel as a transform instead.

const DURATION = 460
const WAVE = 200
const EASING = "cubic-bezier(.2,.85,.2,1)"
const LAYOUT_LIMIT = 260

function reducedMotion() {
  return typeof window !== "undefined" && window.matchMedia
    ? window.matchMedia("(prefers-reduced-motion: reduce)").matches
    : false
}

function px(rect) {
  return { left: `${rect.x}px`, top: `${rect.y}px`, width: `${rect.w}px`, height: `${rect.h}px` }
}

function moved(a, b) {
  return Math.abs(a.x - b.x) > 0.5 || Math.abs(a.y - b.y) > 0.5 || Math.abs(a.w - b.w) > 0.5 || Math.abs(a.h - b.h) > 0.5
}

/**
 * A rect in the old layout, as a place on the layer now. The layer's scroll changed with the
 * style, so `shift` keeps it where it was on screen. One that was far away arrives from the edge
 * of the screen rather than crossing it at a speed nobody can follow.
 */
function onScreen(rect, shift, { top, height }) {
  const y = rect.y + shift
  const reach = height * 0.6
  return { ...rect, y: Math.min(top + height + reach, Math.max(top - reach - rect.h, y)) }
}

function delayFor(rect, focusX, focusY, reach) {
  const distance = Math.hypot(rect.x + rect.w / 2 - focusX, rect.y + rect.h / 2 - focusY)
  return Math.min(1, distance / reach) * WAVE
}

/**
 * A tile fills only backwards, to hold its start through the wave's delay. Filling forwards would
 * leave the finished animation in force, and it would outrank the inline place of every later
 * zoom or resize. A tile on its way out keeps its end state until it is removed.
 */
function travel(node, from, to, delay, options, heavy) {
  const fade = options.fade ? [options.fade[0], options.fade[1]] : [1, 1]
  const keyframes = heavy
    ? [
        {
          transform: `translate(${from.x - to.x}px, ${from.y - to.y}px) scale(${from.w / to.w || 1}, ${from.h / to.h || 1})`,
          transformOrigin: "0 0",
          opacity: fade[0]
        },
        { transform: "none", transformOrigin: "0 0", opacity: fade[1] }
      ]
    : [{ ...px(from), opacity: fade[0] }, { ...px(to), opacity: fade[1] }]
  return node.animate(keyframes, { duration: DURATION, delay, easing: EASING, fill: options.fill || "backwards" })
}

/**
 * Run the change. `tiles` is the pool after it, `from` the rects tiles had before, `leaving` the
 * nodes that have gone from the pool, still in the page. `previousRect` and `nextRect` place a
 * file by its position in the library, in the old and the new style.
 */
export function morph({ tiles, from, leaving, shift, viewport, focusX, focusY, previousRect, nextRect }) {
  const clear = (node) => node.remove()
  if (reducedMotion() || typeof Element === "undefined" || !Element.prototype.animate) {
    leaving.forEach(clear)
    return
  }

  const reach = Math.max(1, viewport.height * 0.9)
  const nodes = [...tiles].filter(([key]) => !key.startsWith("header:"))
  const heavy = nodes.length + leaving.size > LAYOUT_LIMIT

  for (const [key, node] of nodes) {
    const to = {
      x: parseFloat(node.style.left),
      y: parseFloat(node.style.top),
      w: parseFloat(node.style.width),
      h: parseFloat(node.style.height)
    }
    const known = from.get(key) || previousRect(Number(node.dataset.global))
    if (!known) {
      travel(node, { ...to, y: to.y + 24 }, to, delayFor(to, focusX, focusY, reach), { fade: [0, 1] }, heavy)
      continue
    }
    const start = onScreen(known, shift, viewport)
    if (moved(start, to)) travel(node, start, to, delayFor(to, focusX, focusY, reach), {}, heavy)
  }

  // Off the screen in the new style: go there, fading, and only then leave the page.
  for (const [key, node] of leaving) {
    const start = onScreen(from.get(key) || { x: 0, y: 0, w: 1, h: 1 }, shift, viewport)
    const target = nextRect(Number(node.dataset.global))
    node.style.left = `${start.x}px`
    node.style.top = `${start.y}px`
    node.style.width = `${start.w}px`
    node.style.height = `${start.h}px`
    const to = target ? onScreen(target, 0, viewport) : start
    travel(node, start, to, delayFor(start, focusX, focusY, reach), { fade: [1, 0], fill: "both" }, false).finished
      .then(() => clear(node), () => clear(node))
  }
}
