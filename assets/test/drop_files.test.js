import { test } from "node:test"
import assert from "node:assert/strict"

import { carriesFiles, extensionOf, isHidden, acceptable, chunk, filesFromDrop } from "../js/drop_files.js"

const ACCEPT = [".jpg", ".png", ".heic", ".mov"]

// Fakes of the browser's FileSystemEntry shapes: a file, and a directory whose reader
// hands its children out in batches and then an empty batch, as the real one does.
const file = (name, size = 1) => ({ name, size })
const fileEntry = name => ({ isFile: true, isDirectory: false, name, file: ok => ok(file(name)) })
const dirEntry = (name, children, batch = 2) => ({
  isFile: false,
  isDirectory: true,
  name,
  createReader() {
    let at = 0
    return {
      readEntries(ok) {
        const part = children.slice(at, at + batch)
        at += batch
        ok(part)
      }
    }
  }
})
const item = entry => ({ kind: "file", webkitGetAsEntry: () => entry, getAsFile: () => null })
const dropOf = (...entries) => ({ items: entries.map(item), files: [] })
const names = result => result.files.map(f => f.name)

test("carriesFiles: files, not text or links", () => {
  assert.equal(carriesFiles({ types: ["Files"] }), true)
  assert.equal(carriesFiles({ types: ["text/plain", "Files"] }), true)
  assert.equal(carriesFiles({ types: ["text/plain"] }), false)
  assert.equal(carriesFiles({ types: ["text/uri-list"] }), false)
  assert.equal(carriesFiles({}), false)
  assert.equal(carriesFiles(null), false)
})

test("extensionOf is lower-case with the dot, and empty for none", () => {
  assert.equal(extensionOf("IMG_0001.HEIC"), ".heic")
  assert.equal(extensionOf("a.tar.gz"), ".gz")
  assert.equal(extensionOf("README"), "")
  assert.equal(extensionOf(".hidden"), "")
  assert.equal(extensionOf(null), "")
})

test("hidden: dotfiles and the operating system's own litter", () => {
  for (const name of [".DS_Store", "._IMG_1.jpg", ".hidden", "Thumbs.db", "desktop.ini"]) assert.equal(isHidden(name), true, name)
  for (const name of ["IMG_1.jpg", "my.photo.png", "Thumbs.jpg"]) assert.equal(isHidden(name), false, name)
})

test("acceptable: not hidden, and one of the accepted extensions when a list is given", () => {
  assert.equal(acceptable("a.JPG", ACCEPT), true)
  assert.equal(acceptable("a.heic", ACCEPT), true)
  assert.equal(acceptable("a.xmp", ACCEPT), false)
  assert.equal(acceptable("a.json", ACCEPT), false)
  assert.equal(acceptable(".DS_Store", ACCEPT), false)
  assert.equal(acceptable("anything.xyz", null), true)
  assert.equal(acceptable("anything.xyz", []), true)
  assert.equal(acceptable("._a.jpg", null), false)
})

test("chunk cuts a list into arrays of at most n", () => {
  assert.deepEqual(chunk([1, 2, 3, 4, 5], 2), [[1, 2], [3, 4], [5]])
  assert.deepEqual(chunk([], 3), [])
  assert.deepEqual(chunk([1, 2], 10), [[1, 2]])
  assert.deepEqual(chunk([1, 2, 3], 0), [[1], [2], [3]])
})

test("a drop of plain files", async () => {
  const result = await filesFromDrop(dropOf(fileEntry("a.jpg"), fileEntry("b.heic")), { accept: ACCEPT })
  assert.deepEqual(names(result), ["a.jpg", "b.heic"])
  assert.equal(result.skipped, 0)
  assert.equal(result.truncated, false)
})

test("a dropped folder is opened, nested, whatever the batch size of its reader", async () => {
  const tree = dirEntry("Holiday", [
    fileEntry("1.jpg"),
    fileEntry("2.jpg"),
    dirEntry("Day 2", [fileEntry("3.jpg"), fileEntry("4.mov"), dirEntry("raw", [fileEntry("5.png")], 1)], 2),
    fileEntry("6.heic")
  ])

  const result = await filesFromDrop(dropOf(tree), { accept: ACCEPT })

  assert.deepEqual(names(result).sort(), ["1.jpg", "2.jpg", "3.jpg", "4.mov", "5.png", "6.heic"])
})

test("sidecars and litter are skipped and counted; hidden folders are not entered", async () => {
  const tree = dirEntry("Camera", [
    fileEntry("IMG_1.jpg"),
    fileEntry("IMG_1.xmp"),
    fileEntry("IMG_1.aae"),
    fileEntry(".DS_Store"),
    fileEntry("notes.txt"),
    dirEntry(".thumbnails", [fileEntry("hidden-in-dotdir.jpg")]),
    fileEntry("IMG_2.heic")
  ])

  const result = await filesFromDrop(dropOf(tree), { accept: ACCEPT })

  assert.deepEqual(names(result), ["IMG_1.jpg", "IMG_2.heic"])
  assert.equal(result.skipped, 3) // .xmp, .aae, .txt (the dotfile and dot-folder are not counted)
})

test("several things in one drop: files and folders together", async () => {
  const result = await filesFromDrop(
    dropOf(fileEntry("loose.jpg"), dirEntry("Folder", [fileEntry("in.png")])),
    { accept: ACCEPT }
  )
  assert.deepEqual(names(result).sort(), ["in.png", "loose.jpg"])
})

test("a limit stops the walk and says so", async () => {
  const many = dirEntry("Big", Array.from({ length: 50 }, (_, i) => fileEntry(`p${i}.jpg`)), 7)
  const result = await filesFromDrop(dropOf(many), { accept: ACCEPT, limit: 20 })
  assert.equal(result.files.length, 20)
  assert.equal(result.truncated, true)
})

test("a browser with no entries API falls back to the files themselves", async () => {
  const noEntries = { kind: "file", getAsFile: () => file("a.jpg") }
  const result = await filesFromDrop({ items: [noEntries, { kind: "string" }], files: [] }, { accept: ACCEPT })
  assert.deepEqual(names(result), ["a.jpg"])

  const flat = await filesFromDrop({ files: [file("b.png"), file("c.pdf")] }, { accept: ACCEPT })
  assert.deepEqual(names(flat), ["b.png"])
  assert.equal(flat.skipped, 1)
})

test("an unreadable file is skipped, not fatal; so is an unreadable folder", async () => {
  const broken = { isFile: true, isDirectory: false, name: "bad.jpg", file: (_ok, fail) => fail(new Error("denied")) }
  const brokenDir = {
    isFile: false,
    isDirectory: true,
    name: "locked",
    createReader: () => ({ readEntries: (_ok, fail) => fail(new Error("denied")) })
  }
  const result = await filesFromDrop(dropOf(broken, brokenDir, fileEntry("fine.jpg")), { accept: ACCEPT })
  assert.deepEqual(names(result), ["fine.jpg"])
  assert.equal(result.skipped, 1)
  assert.equal(result.unreadable, 1)
})

test("nothing dropped is an empty result", async () => {
  assert.deepEqual(await filesFromDrop(null), { files: [], skipped: 0, unreadable: 0, truncated: false })
  assert.deepEqual(await filesFromDrop({ items: [], files: [] }), { files: [], skipped: 0, unreadable: 0, truncated: false })
})
