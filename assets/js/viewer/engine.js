// The swipe viewer is a set of interchangeable engines behind one small contract,
// so the timeline does not care which library turns the pages, and a host can
// offer more than one.
//
// An engine is a class with a static `id` (what the host names it) and `label`
// (what a picker shows), constructed with the `host` the timeline passes:
//
//   host.store          SlideStore: `total`, `get(index)` -> slide | null. A slide is
//                       `{ id, kind: "image", w, h, src }` or
//                       `{ id, kind: "video", w, h, poster, sources }`.
//   host.thumbOf(id)    URL of the grid tile's picture (already loaded), or undefined
//   host.tileImage(i)   the tile's <img> when it is on screen, else null (an engine
//                       that can fly to a tile does; the others fade)
//   host.video          a VideoController: build / play / pause for video slides
//   host.onInfo(id)     the person asked for the host's own viewer (details)
//   host.onChange(i)    the page turned to index i
//   host.onClose()      the viewer is gone (however it closed)
//
// and implementing:
//
//   open(index)         show the viewer on `index`
//   close()             close it (animated if the engine animates)
//   goTo(index)         (optional) turn to `index`, when the address names another photo
//   destroy()           remove it at once, no callbacks needed
//   refresh(indices)    slides at these indices arrived: draw them where a
//                       placeholder was
//   isOpen, index       state
//
// The engine owns gestures, transitions and the DOM; the timeline owns the data
// (what is loaded, what to ask the server for next) and the grid.

const engines = new Map()

/** Make `id` an engine: `load()` resolves to the engine class (a dynamic import). */
export function registerEngine(id, load) {
  engines.set(id, load)
}

export function engineIds() {
  return [...engines.keys()]
}

export const DEFAULT_ENGINE = "photoswipe"

/**
 * The engine named by the host's `pager` setting: false or empty means none (the
 * host's own viewer), "true" the default engine, an id that is registered that
 * engine, and an id that is not the default (a typo must not break opening photos).
 */
export function engineFor(setting) {
  const value = String(setting ?? "").trim()
  if (value === "" || value === "false") return null
  if (value === "true") return DEFAULT_ENGINE
  if (engines.has(value)) return value
  return DEFAULT_ENGINE
}

/** Load the class of engine `id` (see `engineFor`). */
export async function loadEngine(id) {
  const load = engines.get(id) || engines.get(DEFAULT_ENGINE)
  return load()
}

/**
 * True while a modal dialog is open over the page, the host's own viewer for one:
 * the keys are then the dialog's, and an engine must leave them alone.
 */
export function dialogOpen() {
  try {
    return document.querySelector("dialog:modal") !== null
  } catch (_error) {
    return false // a browser without :modal
  }
}
