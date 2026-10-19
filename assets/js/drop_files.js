// What a drop carries, as files. Pure functions over the browser's DataTransfer
// shapes, so they are testable without a browser; the hook only wires them up.
//
// A dropped FOLDER is not in `dataTransfer.files` (the browser lists the folder
// itself as a file of size 0 that cannot be read). Its contents are reachable only
// through `webkitGetAsEntry()`, which must be called synchronously inside the drop
// event and then walked asynchronously, and a directory reader hands its entries
// out in batches of at most about a hundred until it returns an empty one.

/** Whether a drag carries files (not text, a link or an element being dragged). */
export function carriesFiles(dataTransfer) {
  const types = dataTransfer && dataTransfer.types ? Array.from(dataTransfer.types) : []
  return types.includes("Files")
}

/** The lower-case extension with its dot (".heic"), or "". */
export function extensionOf(name) {
  const i = String(name || "").lastIndexOf(".")
  return i > 0 ? name.slice(i).toLowerCase() : ""
}

/** The operating system's own litter: dotfiles and the few known thumbnails databases. */
export function isHidden(name) {
  const n = String(name || "")
  return n.startsWith(".") || n === "Thumbs.db" || n === "desktop.ini"
}

/**
 * Whether a file is worth offering: not hidden, and (when an accept list of
 * extensions is given) one of those. The server decides what it really takes; this
 * keeps a folder's sidecars (.xmp, .json, .aae) from being counted as failures.
 */
export function acceptable(name, accept) {
  if (isHidden(name)) return false
  if (!accept || accept.length === 0) return true
  return accept.includes(extensionOf(name))
}

/** `list` cut into arrays of at most `size`. */
export function chunk(list, size) {
  const n = Math.max(1, size | 0)
  const out = []
  for (let i = 0; i < list.length; i += n) out.push(list.slice(i, i + n))
  return out
}

const fileOf = entry => new Promise((resolve, reject) => entry.file(resolve, reject))

async function readAll(reader) {
  const all = []
  for (;;) {
    const batch = await new Promise((resolve, reject) => reader.readEntries(resolve, reject))
    if (!batch || batch.length === 0) return all
    all.push(...batch)
  }
}

async function walk(entry, out, accept, state) {
  if (state.count >= state.limit) {
    state.truncated = true
    return
  }

  if (entry.isFile) {
    if (isHidden(entry.name)) return
    let file
    try {
      file = await fileOf(entry)
    } catch (_error) {
      state.skipped++
      return
    }
    if (acceptable(file.name, accept)) {
      out.push(file)
      state.count++
    } else {
      state.skipped++
    }
  } else if (entry.isDirectory) {
    if (isHidden(entry.name)) return
    let children
    try {
      children = await readAll(entry.createReader())
    } catch (_error) {
      // A folder the browser will not open (a permission, a network drive, a drag the
      // page has no file-system handle for): counted, so the person is told.
      state.unreadable++
      return
    }
    for (const child of children) await walk(child, out, accept, state)
  }
}

/**
 * The files of a drop, folders opened. Must be CALLED inside the drop handler (the
 * entries are collected before the first await, because the browser invalidates the
 * DataTransfer once the handler returns); the walking then continues asynchronously.
 *
 * Returns `{ files, skipped, unreadable, truncated }`: the files to offer, how many were
 * left out (hidden, or not an accepted kind), how many folders could not be read, and
 * whether `limit` stopped the walk.
 */
export async function filesFromDrop(dataTransfer, { accept = null, limit = 20000 } = {}) {
  const items = dataTransfer && dataTransfer.items ? Array.from(dataTransfer.items) : []
  const entries = []
  const plain = []

  for (const item of items) {
    if (item.kind !== "file") continue
    const entry = typeof item.webkitGetAsEntry === "function" ? item.webkitGetAsEntry() : null
    if (entry) entries.push(entry)
    else {
      const file = item.getAsFile && item.getAsFile()
      if (file) plain.push(file)
    }
  }

  // A browser with no items API: the flat list is all there is.
  if (items.length === 0 && dataTransfer && dataTransfer.files) plain.push(...Array.from(dataTransfer.files))

  const state = { skipped: 0, unreadable: 0, count: 0, limit, truncated: false }
  const files = []

  for (const file of plain) {
    if (acceptable(file.name, accept)) {
      files.push(file)
      state.count++
    } else state.skipped++
  }

  for (const entry of entries) await walk(entry, files, accept, state)

  return { files, skipped: state.skipped, unreadable: state.unreadable, truncated: state.truncated }
}
