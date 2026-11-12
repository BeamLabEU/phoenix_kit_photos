// What every engine does for a video slide, so playing is the same whichever
// library turns the pages: a <video> that shows the poster and fetches nothing
// until it is played, picks the file that suits the screen, falls back to the
// next listed file when one fails, and keeps the person's mute choice.

import { chooseSource } from "../slides.js"

export function defaultEnv() {
  const probe = document.createElement("video")
  return {
    hdrScreen: !!(window.matchMedia && window.matchMedia("(dynamic-range: high)").matches),
    canPlay: (type) => !!type && probe.canPlayType(type) !== ""
  }
}

export class VideoController {
  constructor(env) {
    this.env = env || defaultEnv()
    this.muted = true
  }

  /** A <video> for `slide` (`poster`, `sources`), not yet loading anything. */
  build(slide) {
    const video = document.createElement("video")
    video.className = "pk-pager__video"
    video.controls = true
    video.playsInline = true
    video.setAttribute("playsinline", "")
    video.preload = "none"
    video.muted = this.muted
    if (slide.poster) video.poster = slide.poster
    video.pkSources = slide.sources || []
    video.pkTried = null

    video.addEventListener("playing", () => (video.pkPlaying = true))
    video.addEventListener("pause", () => (video.pkPlaying = false))
    video.addEventListener("volumechange", () => {
      this.muted = video.muted
    })
    video.addEventListener("error", () => this.next(video))
    // Its own play button, pressed before the engine chose a file: choose one now, or
    // the press does nothing at all.
    video.addEventListener("play", () => {
      if (video.pkTried === null) this.play(video)
    })
    return video
  }

  /** The slide is on screen: choose a file the first time, then play (muted until the person unmutes). */
  play(video) {
    if (!video) return
    if (video.pkTried === null) {
      const first = chooseSource(video.pkSources, this.env)
      video.pkTried = first ? [first.url] : []
      if (first) {
        video.src = first.url
        video.preload = "auto"
      }
    }

    video.muted = this.muted
    this.start(video)
  }

  pause(video) {
    if (video) video.pause()
  }

  // The file failed (a codec this browser lacks, a dead link): try the next listed one.
  // A network error after the file had started is most likely the storage's signed link
  // expiring while the video played: the browser keeps reading the address it was
  // redirected to and never asks ours again. So the same file is asked for afresh
  // (ours answers with a new link) and picks up where it was, at most once a minute.
  next(video) {
    if (video.pkTried === null) return
    if (this.resume(video)) return
    const source = video.pkSources.find((s) => !video.pkTried.includes(s.url))
    if (!source) return
    video.pkTried.push(source.url)
    video.src = source.url
    video.load()
    this.start(video)
  }

  resume(video, now = Date.now()) {
    const NETWORK = 2 // MediaError.MEDIA_ERR_NETWORK
    const url = video.pkTried[video.pkTried.length - 1]
    const at = video.currentTime || 0
    if (!url || !video.error || video.error.code !== NETWORK || !(at > 0)) return false
    if (video.pkResumedAt && now - video.pkResumedAt < 60_000) return false

    video.pkResumedAt = now
    const playing = video.pkPlaying === true
    video.addEventListener(
      "loadedmetadata",
      () => {
        video.currentTime = at
        if (playing) this.start(video)
      },
      { once: true }
    )
    video.src = url
    video.load()
    return true
  }

  start(video) {
    const attempt = video.play()
    if (attempt && attempt.catch) attempt.catch(() => {})
  }
}

/** The CSS every engine shares (the video box and the waiting spinner). */
export const SHARED_CSS = `
.pk-pager__video { display: block; width: 100%; height: 100%; object-fit: contain; background: #000; }
.pk-pager__wait { width: 100%; height: 100%; display: grid; place-items: center; }
.pk-pager__wait::after { content: ""; width: 28px; height: 28px; border-radius: 50%;
  border: 3px solid rgba(255,255,255,.25); border-top-color: #fff; animation: pk-pager-spin .8s linear infinite; }
@keyframes pk-pager-spin { to { transform: rotate(360deg); } }
`

export function addStyle(id, css) {
  if (document.getElementById(id)) return
  const style = document.createElement("style")
  style.id = id
  style.textContent = css
  document.head.appendChild(style)
}
