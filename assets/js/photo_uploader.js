import { carriesFiles, filesFromDrop, chunk } from "./drop_files.js"

/**
 * The uploader's hook: the whole window is a drop zone while the hook is mounted.
 *
 * Division of labour: LiveView owns permissions, the upload itself and what is stored;
 * this hook owns the drag-and-drop part LiveView does not do. It shows the overlay while
 * files are dragged over the page, opens dropped FOLDERS (LiveView sees a folder as an
 * empty file), leaves out a folder's sidecars and the system's litter, and feeds the
 * files to the server in batches the upload can take, the next batch when the server
 * says nothing is left in flight, so dropping a library of thousands does not ask
 * LiveView to track thousands of entries at once. "Is anything in flight?" is asked of
 * the component (a `ready` event with a reply) every half second while files are
 * waiting; the server could not push the answer, because an event pushed from a
 * component's upload-progress callback never reaches the page.
 *
 * Nothing here knows about Elixir, Ecto or PhoenixKit: the contract is the element's
 * data attributes (`data-upload-name`, `data-accept`, `data-batch`) and the events
 * `dropped`, `waiting` and `ready` (replying `{idle: boolean}`).
 *
 * The hook name must stay globally unique (see `PhotoTimeline`).
 */
export const PhotoUploader = {
  mounted() {
    this.name = this.el.dataset.uploadName || "photos"
    this.accept = parseList(this.el.dataset.accept)
    this.batch = Math.max(1, parseInt(this.el.dataset.batch || "100", 10) || 100)
    this.queue = []
    this.draining = false
    this.gone = false
    this.depth = 0
    this.dragging = false

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
  // `data-active`; the drag is still going on.
  updated() {
    this.paint()
  },

  destroyed() {
    this.gone = true
    window.removeEventListener("dragenter", this.onEnter)
    window.removeEventListener("dragover", this.onOver)
    window.removeEventListener("dragleave", this.onLeave)
    window.removeEventListener("drop", this.onDrop)
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
      this.pushEventTo(this.el, "dropped", { files: files.length, skipped, unreadable, truncated })
      this.queue.push(...files)
      this.drain()
    })
  },

  // Sends the queue on, a batch at a time, whenever the server has nothing in flight.
  async drain() {
    if (this.draining) return
    this.draining = true

    try {
      while (this.queue.length > 0 && !this.gone) {
        const idle = await this.ready()

        if (idle && !this.gone) {
          const [next] = chunk(this.queue, this.batch)
          this.queue = this.queue.slice(next.length)
          this.uploadTo(this.el, this.name, next)
          this.pushEventTo(this.el, "waiting", { count: this.queue.length })
        }

        // After a batch, long enough for the server to have registered its entries
        // before it is asked again; while it is busy, a steady poll.
        await sleep(idle ? 300 : 500)
      }
    } finally {
      this.draining = false
    }
  },

  // Whether the component has nothing uploading or waiting to be uploaded. No answer in
  // five seconds (a lost connection) counts as busy.
  ready() {
    return new Promise(resolve => {
      const timer = setTimeout(() => resolve(false), 5000)
      this.pushEventTo(this.el, "ready", {}, reply => {
        clearTimeout(timer)
        resolve(Boolean(reply && reply.idle))
      })
    })
  }
}

const sleep = ms => new Promise(resolve => setTimeout(resolve, ms))

function parseList(json) {
  try {
    const list = JSON.parse(json || "[]")
    return Array.isArray(list) ? list.map(String) : []
  } catch (_error) {
    return []
  }
}
