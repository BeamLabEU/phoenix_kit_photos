/**
 * A small picture of a file that is about to be uploaded, made in the browser, for the
 * uploader's tiles: the photo itself scaled down, or a frame of a video. Returns an
 * object URL of a JPEG about `SIDE` px on its shorter side, or null when the browser
 * cannot read the file (a HEIC outside Safari, camera raw) or takes too long; the tile
 * then shows its plain icon. Nothing is sent anywhere, and nothing here throws.
 *
 * The caller revokes the URL (`URL.revokeObjectURL`) when the tile is gone.
 */
const SIDE = 256
const VIDEO_TIMEOUT_MS = 5000

export async function makePreview(file, env = globalThis) {
  try {
    if (!file || !env.document || !env.URL) return null
    const canvas = isVideo(file) ? await videoFrame(file, env) : await imageFrame(file, env)
    return canvas ? await canvasUrl(canvas, env) : null
  } catch (_error) {
    return null
  }
}

export function isVideo(file) {
  const type = String((file && file.type) || "")
  if (type !== "") return type.startsWith("video/")
  return /\.(mp4|mov|webm|3gp|m4v)$/i.test(String((file && file.name) || ""))
}

/** The box a `width` x `height` picture is drawn in: its shorter side `side`, never enlarged. */
export function fit(width, height, side = SIDE) {
  if (!(width > 0) || !(height > 0)) return null
  const scale = Math.min(1, side / Math.min(width, height))
  return { width: Math.max(1, Math.round(width * scale)), height: Math.max(1, Math.round(height * scale)) }
}

async function imageFrame(file, env) {
  if (typeof env.createImageBitmap !== "function") return null
  let bitmap
  try {
    // Scaled while it is decoded, where the browser can: a 50-megapixel photo never
    // sits in memory at full size.
    bitmap = await env.createImageBitmap(file, { resizeHeight: SIDE, resizeQuality: "low" })
  } catch (_error) {
    bitmap = await env.createImageBitmap(file)
  }
  try {
    return draw(bitmap, bitmap.width, bitmap.height, env)
  } finally {
    if (bitmap.close) bitmap.close()
  }
}

function videoFrame(file, env) {
  return new Promise(resolve => {
    const video = env.document.createElement("video")
    const url = env.URL.createObjectURL(file)
    let done = false

    const finish = canvas => {
      if (done) return
      done = true
      clearTimeout(timer)
      video.removeAttribute("src")
      try {
        video.load()
      } catch (_error) {
        // Already torn down.
      }
      env.URL.revokeObjectURL(url)
      resolve(canvas)
    }

    const timer = setTimeout(() => finish(null), VIDEO_TIMEOUT_MS)
    video.muted = true
    video.playsInline = true
    video.preload = "auto"
    video.onerror = () => finish(null)
    // The very first frame is often black: a little way in, or the middle of a short clip.
    video.onloadeddata = () => {
      try {
        video.currentTime = Math.min(0.5, (video.duration || 1) / 2)
      } catch (_error) {
        finish(null)
      }
    }
    video.onseeked = () => {
      try {
        finish(draw(video, video.videoWidth, video.videoHeight, env))
      } catch (_error) {
        finish(null)
      }
    }
    video.src = url
  })
}

function draw(source, width, height, env) {
  const box = fit(width, height)
  if (!box) return null
  const canvas = env.document.createElement("canvas")
  canvas.width = box.width
  canvas.height = box.height
  canvas.getContext("2d").drawImage(source, 0, 0, box.width, box.height)
  return canvas
}

function canvasUrl(canvas, env) {
  return new Promise(resolve => {
    canvas.toBlob(blob => resolve(blob ? env.URL.createObjectURL(blob) : null), "image/jpeg", 0.7)
  })
}
