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

    video.addEventListener("volumechange", () => {
      this.muted = video.muted
    })
    video.addEventListener("error", () => this.next(video))
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
  next(video) {
    if (video.pkTried === null) return
    const source = video.pkSources.find((s) => !video.pkTried.includes(s.url))
    if (!source) return
    video.pkTried.push(source.url)
    video.src = source.url
    video.load()
    this.start(video)
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
