import { carriesFiles, filesFromDrop } from "./drop_files.js"
import { makePreview, offerPreview, withdrawPreviews } from "./upload_previews.js"

/**
 * The uploader's hook: the whole window is a drop zone while the hook is mounted.
 *
 * Division of labour: LiveView owns permissions, the upload itself and what is stored;
 * this hook owns the drag-and-drop part LiveView does not do. It shows the overlay while
 * files are dragged over the page, opens dropped FOLDERS (LiveView sees a folder as an
 * empty file), leaves out a folder's sidecars and the system's litter, and feeds the
 * files — dropped or chosen in the picker, which the hook takes over from LiveView —
 * to the server in a sliding window: at most as many in flight as the panel's
 * "Uploads at once" control says (the `data-concurrency-select` element, kept in
 * localStorage), and never more than one batch (`data-batch`), so dropping a library of
 * thousands does not ask LiveView to track thousands of entries at once. In a public
 * library (`data-auto="false"`) nothing is sent until the Upload button's submit.
 * "How much is
 * in flight?" is asked of the component (a `ready` event with a reply) while files are
 * waiting; the server could not push the answer, because an event pushed from a
 * component's upload-progress callback never reaches the page.
 *
 * It also draws the tiles' pictures. The component renders a tile per file on its way
 * with an empty `data-upload-preview="<ref>"` slot it never touches again
 * (`phx-update="ignore"`); the hook makes a small picture of each file it handed to
 * LiveView (`upload_previews.js`), one at a time, and puts it in the slot. Which file a
 * tile is for is told by `data-previews` (`[[ref, name, size], …]` for the entries
 * uploading), and `data-refs` lists every file still on its way (uploading, saving,
 * previews being made), so a picture is kept exactly that long and then released.
 * While a stored file's own sizes are being made (`data-preparing`, `[[ref, file id], …]`)
 * its picture is also offered to the timeline under the file's id (`upload_previews.js`,
 * `offerPreview`), which draws the file's tile with it until the real one is ready.
 *
 * Nothing here knows about Elixir, Ecto or PhoenixKit: the contract is the element's
 * data attributes (`data-upload-name`, `data-accept`, `data-batch`,
 * `data-concurrency`, `data-concurrency-max`, and `data-cancel-all` on the button that
 * empties this queue too) and the events `dropped`, `waiting` (count plus the first
 * queued names) and `ready` (replying `{idle: boolean, in_flight: number}`).
 *
 * The hook name must stay globally unique (see `PhotoTimeline`).
 */
const CONCURRENCY_KEY = "phoenix_kit_photos:upload_concurrency"

// How many queued file names are told to the server for the panel to list; the rest
// is only counted, so a drop of thousands does not push thousands of names per batch.
const MAX_QUEUED_NAMES = 50

// How many handed-over files are remembered until their tile asks for a picture: a file
// the server turned away never gets a tile, and must not be held for good.
const MAX_HANDED = 400

export const PhotoUploader = {
  mounted() {
    this.name = this.el.dataset.uploadName || "photos"
    this.accept = parseList(this.el.dataset.accept)
    this.batch = Math.max(1, parseInt(this.el.dataset.batch || "100", 10) || 100)
    this.maxConcurrency = Math.max(1, parseInt(this.el.dataset.concurrencyMax || "8", 10) || 8)
    this.concurrency = this.readConcurrency()
    // A public library waits for Upload before anything is sent (`data-auto="false"`):
    // files picked or dropped sit in the queue (listed as waiting) until the form's
    // submit, then the window applies like everywhere else. The submit listener only
    // observes — LiveView still gets the event.
    this.gated = this.el.dataset.auto === "false"
    this.started = !this.gated
    this.onSubmit = () => {
      this.started = true
    }
    this.el.addEventListener("submit", this.onSubmit)
    this.queue = []
    this.draining = false
    this.gone = false
    this.depth = 0
    this.dragging = false
    this.handed = []
    this.previews = new Map()
    this.previewWork = Promise.resolve()

    // The panel's concurrency control: purely client-side, kept in localStorage.
    this.onConcurrencyChange = event => {
      const target = event.target
      if (target && target.closest && target.closest("[data-concurrency-select]")) {
        this.setConcurrency(target.value)
      }
    }
    this.el.addEventListener("change", this.onConcurrencyChange)

    // Files chosen in the picker go through the same window as drops, so the
    // concurrency control covers them too. A picker fires `input` and then `change`
    // on the file input, and LiveView listens for BOTH on `window`, registering and
    // starting every picked file on the first one; both are stopped here, in the
    // capture phase on this ancestor, which runs before any window listener. The
    // `input` event LiveView itself dispatches after `uploadTo` finds no files (the
    // input's value was reset), so it passes through untouched.
    this.onInputChange = event => {
      const input = event.target
      if (!input || !input.matches || !input.matches("input[type=file]")) return
      if (!input.files || input.files.length === 0) return
      event.preventDefault()
      event.stopPropagation()
      const files = Array.from(input.files)
      input.value = "" // so picking the same files again fires the events again
      this.takeFiles(files)
    }
    this.el.addEventListener("input", this.onInputChange, true)
    this.el.addEventListener("change", this.onInputChange, true)

    // Cancel all also empties the hook's own queue of not-yet-sent files.
    this.onClick = event => {
      const target = event.target
      if (target && target.closest && target.closest("[data-cancel-all]")) this.queue = []
    }
    this.el.addEventListener("click", this.onClick)

    // A drop on the file input itself is the browser's own business (it sets the
    // input's files and LiveView hears the change); doing it twice would add every
    // file twice.
    const onInput = event => event.target && event.target.closest && event.target.closest("input[type=file]")

    this.onEnter = event => {
      if (!carriesFiles(event.dataTransfer)) return
      this.depth += 1
      this.setDragging(true)
    }

    this.onOver = event => {
      if (!carriesFiles(event.dataTransfer) || onInput(event)) return
      event.preventDefault() // what makes the page a place files may be dropped
      event.dataTransfer.dropEffect = "copy"
    }

    this.onLeave = event => {
      if (!carriesFiles(event.dataTransfer)) return
      this.depth = Math.max(0, this.depth - 1)
      if (this.depth === 0) this.setDragging(false)
    }

    this.onDrop = event => {
      if (!carriesFiles(event.dataTransfer) || onInput(event)) return
      // Without this the browser opens the file in place of the page.
      event.preventDefault()
      this.depth = 0
      this.setDragging(false)
      this.take(event.dataTransfer)
    }

    window.addEventListener("dragenter", this.onEnter)
    window.addEventListener("dragover", this.onOver)
    window.addEventListener("dragleave", this.onLeave)
    window.addEventListener("drop", this.onDrop)
  },

  // LiveView patches the element back to what the server rendered, which has no
  // `data-active` (the drag is still going on) and the control's default selection.
  updated() {
    this.paint()
    const gated = this.el.dataset.auto === "false"
    if (gated !== this.gated) {
      this.gated = gated
      this.started = !gated
    }
    const select = this.el.querySelector("[data-concurrency-select]")
    if (select) select.value = String(this.concurrency)
    this.syncPreviews()
  },

  destroyed() {
    this.gone = true
    this.releasePreviews()
    window.removeEventListener("dragenter", this.onEnter)
    window.removeEventListener("dragover", this.onOver)
    window.removeEventListener("dragleave", this.onLeave)
    window.removeEventListener("drop", this.onDrop)
    this.el.removeEventListener("change", this.onConcurrencyChange)
    this.el.removeEventListener("input", this.onInputChange, true)
    this.el.removeEventListener("change", this.onInputChange, true)
    this.el.removeEventListener("click", this.onClick)
    this.el.removeEventListener("submit", this.onSubmit)
  },

  // The control's value: a saved choice, else the server's default, clamped to
  // [1, maxConcurrency]. Never above the batch, or LiveView would refuse the entries.
  readConcurrency() {
    let saved = NaN
    try {
      saved = parseInt(window.localStorage.getItem(CONCURRENCY_KEY) || "", 10)
    } catch (_error) {
      // Storage may be denied by browser policy; use the server's default.
    }
    const fallback = parseInt(this.el.dataset.concurrency || "", 10)
    const base = !isNaN(saved) ? saved : !isNaN(fallback) ? fallback : 4
    return clamp(base, 1, Math.min(this.maxConcurrency, this.batch))
  },

  setConcurrency(value) {
    this.concurrency = clamp(parseInt(value, 10) || 4, 1, Math.min(this.maxConcurrency, this.batch))
    try {
      window.localStorage.setItem(CONCURRENCY_KEY, String(this.concurrency))
    } catch (_error) {
      // Private mode and the like: the choice just does not survive a reload.
    }
    const select = this.el.querySelector("[data-concurrency-select]")
    if (select) select.value = String(this.concurrency)
  },

  // Hands files to LiveView, remembering them until their tiles ask for a picture.
  send(files) {
    this.handed = (this.handed || []).concat(files).slice(-MAX_HANDED)
    this.uploadTo(this.el, this.name, files)
  },

  // After every patch: start a picture for each new entry, let go of those whose file
  // is no longer on its way, and fill the slots that are in the page.
  syncPreviews() {
    if (!this.previews) return
    const live = new Set(parseList(this.el.dataset.refs))

    for (const [ref, name, size] of parseRows(this.el.dataset.previews)) {
      if (this.previews.has(ref)) continue
      this.previews.set(ref, null)
      const file = this.takeHanded(name, size)
      if (file) this.queuePreview(ref, file)
    }

    for (const [ref, url] of this.previews) {
      if (live.has(ref)) continue
      this.previews.delete(ref)
      withdrawPreviews(url)
      revoke(url)
    }

    this.offerPreviews()

    this.paintPreviews()
  },

  // A stored file's picture, under the file's id, for the timeline's tile of it.
  offerPreviews() {
    for (const [ref, fileId] of parsePairs(this.el.dataset.preparing)) {
      const url = this.previews.get(ref)
      if (url) offerPreview(fileId, url)
    }
  },

  takeHanded(name, size) {
    const at = (this.handed || []).findIndex(f => String(f.name) === name && f.size === size)
    return at < 0 ? null : this.handed.splice(at, 1)[0]
  },

  // One at a time: decoding eight large photos at once would stall the page.
  queuePreview(ref, file) {
    const make = this.makePreview || makePreview
    this.previewWork = this.previewWork
      .then(() => (this.gone || !this.previews.has(ref) ? null : make(file)))
      .then(url => {
        if (!url) return
        if (this.gone || !this.previews.has(ref)) return revoke(url)
        this.previews.set(ref, url)
        this.paintPreviews()
        this.offerPreviews()
      })
      .catch(() => {})
    return this.previewWork
  },

  paintPreviews() {
    this.el.querySelectorAll("[data-upload-preview]").forEach(slot => {
      const url = this.previews.get(slot.dataset.uploadPreview)
      if (!url || slot.firstChild) return
      const img = document.createElement("img")
      img.alt = ""
      img.decoding = "async"
      img.src = url
      slot.appendChild(img)
    })
  },

  releasePreviews() {
    if (!this.previews) return
    for (const url of this.previews.values()) {
      withdrawPreviews(url)
      revoke(url)
    }
    this.previews.clear()
    this.handed = []
  },

  setDragging(on) {
    this.dragging = on
    this.paint()
  },

  paint() {
    const overlay = this.el.querySelector("[data-drop-overlay]")
    if (!overlay) return
    if (this.dragging) overlay.setAttribute("data-active", "")
    else overlay.removeAttribute("data-active")
  },

  // Called inside the drop event: `filesFromDrop` collects the entries before its
  // first await, which is the only moment the browser lets it.
  take(dataTransfer) {
    filesFromDrop(dataTransfer, { accept: this.accept }).then(({ files, skipped, unreadable, truncated }) => {
      this.takeFiles(files, { skipped, unreadable, truncated })
    })
  },

  // Files from a drop or the picker: told to the component (it opens the panel and says
  // what was left out), queued, and drained through the concurrency window.
  takeFiles(files, counts = {}) {
    if (this.gated && files.length > 0) this.started = false
    this.pushEventTo(this.el, "dropped", {
      files: files.length,
      skipped: counts.skipped || 0,
      unreadable: counts.unreadable || 0,
      truncated: counts.truncated === true
    })
    this.queue.push(...files)
    return this.drain()
  },

  // What the panel shows beyond the entries in flight: the count of files still queued,
  // and the first few names, so the whole selection is listed.
  waitingPayload() {
    return {
      count: this.queue.length,
      names: this.queue.slice(0, MAX_QUEUED_NAMES).map(f => String(f.name).slice(0, 255))
    }
  },

  // Sends the queue on, keeping at most `this.concurrency` files in flight: whenever the
  // server says a slot freed up, that many more are handed to LiveView. In a public
  // library nothing is sent until Upload was pressed. A server that answers without
  // `in_flight` (an older one) falls back to the old batch behaviour.
  async drain() {
    if (this.draining) return
    this.draining = true

    try {
      while (this.queue.length > 0 && !this.gone) {
        const state = await this.ready()
        const inFlight = state && Number.isInteger(state.inFlight) ? state.inFlight : null

        if (inFlight !== null && !this.gone) {
          const limit = this.gated && !this.started ? 0 : this.concurrency
          const room = Math.max(0, Math.min(limit - inFlight, this.batch - inFlight))

          if (room > 0) {
            const next = this.queue.slice(0, room)
            this.queue = this.queue.slice(next.length)
            this.send(next)
          }

          // Told every poll, not only when sending: in a public library nothing is
          // sent until Upload, and the panel must still list what is queued.
          this.pushEventTo(this.el, "waiting", this.waitingPayload())

          // After sending, long enough for the server to have registered its entries
          // before it is asked again; while the window is full, a steady poll.
          await sleep(500)
        } else {
          // No `in_flight` in the answer (an older server): a whole batch, and only
          // when the server says nothing is in flight.
          if (state.idle && !this.gone) {
            const next = this.queue.slice(0, this.batch)
            this.queue = this.queue.slice(next.length)
            this.send(next)
          }

          this.pushEventTo(this.el, "waiting", this.waitingPayload())
          await sleep(state.idle ? 300 : 500)
        }
      }
    } finally {
      this.draining = false
    }
  },

  // How many entries the component still has in flight (uploading, or waiting for a
  // click in a public library). No answer in five seconds (a lost connection) counts as
  // a full window, and `in_flight` comes back null so the drain falls back to batches.
  ready() {
    return new Promise(resolve => {
      const timer = setTimeout(() => resolve({ idle: false, inFlight: null }), 5000)
      this.pushEventTo(this.el, "ready", {}, reply => {
        clearTimeout(timer)
        const inFlight = reply && Number.isInteger(reply.in_flight) ? reply.in_flight : null
        resolve({ idle: Boolean(reply && reply.idle), inFlight })
      })
    })
  }
}

const sleep = ms => new Promise(resolve => setTimeout(resolve, ms))

const clamp = (n, low, high) => Math.min(Math.max(isNaN(n) ? low : n, low), high)

function revoke(url) {
  if (url) URL.revokeObjectURL(url)
}

// `[[ref, name, size], …]`, with anything else dropped.
function parseRows(json) {
  try {
    const rows = JSON.parse(json || "[]")
    if (!Array.isArray(rows)) return []
    return rows.filter(row => Array.isArray(row) && row.length === 3).map(([ref, name, size]) => [String(ref), String(name), size])
  } catch (_error) {
    return []
  }
}

// `[[ref, file id], …]`.
function parsePairs(json) {
  try {
    const rows = JSON.parse(json || "[]")
    if (!Array.isArray(rows)) return []
    return rows.filter(row => Array.isArray(row) && row.length === 2).map(([ref, id]) => [String(ref), String(id)])
  } catch (_error) {
    return []
  }
}

function parseList(json) {
  try {
    const list = JSON.parse(json || "[]")
    return Array.isArray(list) ? list.map(String) : []
  } catch (_error) {
    return []
  }
}
