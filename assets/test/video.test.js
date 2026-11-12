import test from "node:test"
import assert from "node:assert/strict"
import { VideoController } from "../js/viewer/video.js"

// A stand-in <video>: what VideoController.resume reads and does.
function fakeVideo({ code = 2, at = 42, playing = true, url = "/file/x/720p/t" } = {}) {
  const listeners = {}
  return {
    error: code ? { code } : null,
    currentTime: at,
    pkPlaying: playing,
    pkTried: [url],
    src: url,
    loads: 0,
    plays: 0,
    addEventListener(name, fn) {
      ;(listeners[name] ||= []).push(fn)
    },
    emit(name) {
      const fns = listeners[name] || []
      listeners[name] = []
      fns.forEach((fn) => fn())
    },
    load() {
      this.loads++
      this.currentTime = 0
    },
    play() {
      this.plays++
      return Promise.resolve()
    }
  }
}

const controller = () => new VideoController({ hdrScreen: false, canPlay: () => true })

test("a network error mid-video asks for the same file again and goes back to where it was", () => {
  const video = fakeVideo()
  assert.equal(controller().resume(video, 1_000_000), true)
  assert.equal(video.loads, 1)
  assert.equal(video.src, "/file/x/720p/t")

  video.emit("loadedmetadata")
  assert.equal(video.currentTime, 42)
  assert.equal(video.plays, 1)
})

test("a paused video comes back paused", () => {
  const video = fakeVideo({ playing: false })
  controller().resume(video, 1_000_000)
  video.emit("loadedmetadata")
  assert.equal(video.currentTime, 42)
  assert.equal(video.plays, 0)
})

test("not for a file that never started, nor for an error that is not the network", () => {
  assert.equal(controller().resume(fakeVideo({ at: 0 }), 1_000_000), false)
  assert.equal(controller().resume(fakeVideo({ code: 4 }), 1_000_000), false)
  assert.equal(controller().resume(fakeVideo({ code: 0 }), 1_000_000), false)
})

test("at most once a minute, so a file that keeps failing moves on to the next one", () => {
  const c = controller()
  const video = fakeVideo()
  assert.equal(c.resume(video, 1_000_000), true)
  video.emit("loadedmetadata") // back at 42 s, playing on
  assert.equal(c.resume(video, 1_030_000), false)
  assert.equal(c.resume(video, 1_061_000), true)
})
