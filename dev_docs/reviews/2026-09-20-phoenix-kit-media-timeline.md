# Review: Photo / Video Timeline plan

Review of `dev_docs/plans/2026-09-20-phoenix-kit-media-timeline.md`.
Verdict: the problem, the LiveView diagnosis, the PhoenixKit facts, and the
package shape are right. Close Stage 0 and a few still-open decisions before
writing grid code. Capture date as sketched is not enough to group a library
by calendar month.

Reviewed against PhoenixKit 2.32.1 as installed in Fotki (`/www/app`, Hex
`phoenix_kit` 2.32.1). This repo (`phoenix_kit_media_timeline`) currently
contains only the plan.

---

## Naming, so this review is not misread

`phoenix_kit_files` is **not a module and not a Hex package**. It is the
Postgres table for original uploads, owned by PhoenixKit core's always-on
Storage module.

| Name | What it is |
|---|---|
| `phoenix_kit` | Hex package (core), 2.32.1 in Fotki |
| `PhoenixKit.Modules.Storage` | Elixir module, `module_key/0` = `"storage"` |
| `PhoenixKit.Modules.Storage.File` | Ecto schema |
| `phoenix_kit_files` | SQL table that schema maps to (`schema "phoenix_kit_files"`) |
| `phoenix_kit_media_timeline` | the package this plan proposes |

When this review says “add `taken_at` to `phoenix_kit_files`,” it means: add
a column on Storage's files table in **PhoenixKit core**. MediaBrowser already
stores images and videos there (`width`, `height`, `file_type`, `user_uuid`,
`trashed_at`, `system_managed`, …). Capture date is missing on that table
today. Fotki created it via
`priv/repo/migrations/20260919235130_add_phoenix_kit_tables.exs` →
`PhoenixKit.Migrations.up/1`.

There is no `PhoenixKitFiles` / `phoenix_kit_files` module to depend on.

---

## Verdict

Ship it as `phoenix_kit_media_timeline`, with Stage 0 as an **upstream
PhoenixKit PR**, not as package-side surgery on the `phoenix_kit_files` table.
Treat the first release as **personal library + square virtualized grid +
date jump**. Albums, shares, justified layout, and the Google-style scrubber
are later product, not the published contract.

The first stone is capture date, as the plan says — but a single
`taken_at :utc_datetime` is not enough to bucket by calendar month.

Do not reopen “generic Hex grid vs PhoenixKit module” or “LiveView streams vs
a JS hook.” Those are settled.

---

## What is already right

**The widget split is correct.** MediaBrowser is file work, MediaGallery is a
form picker, PhotoTimeline is a life by capture date. Mixing any two of those
is how this product gets a second mediocre grid.

**LiveView streams cannot be the scrollbar.** `phx-viewport-*` + `stream`
gives a Twitter window. A Photos scrollbar is a map of time, which needs
section heights before the photos exist. Geometry, recycling, and the scrubber
belong in a hook. LiveView stays permissions, window transport, and PubSub.
That split should hold from day one.

**PhoenixKit facts check out against 2.32.1:**

- `ProcessFileJob.extract_image_metadata/1` writes `width` / `height` /
  `format` only. Video ffprobe does not request `creation_time`.
- `metadata` is documented as EXIF and nothing writes EXIF into it.
- `ImageProcessor.sanitize/3` really does `-strip` (GPS rationale). It is
  not on the general ingest path today.
- Indexes on `phoenix_kit_files` are `inserted_at`, `user_uuid`, `file_type`,
  `status`, `trashed_at` — no `(user_uuid, taken_at DESC)`.
- `system_managed` / `parent_file_uuid` / Tessera tiles / edit backups are
  real and will pollute a naïve query.
- `js_sources/0`, `css_sources/0`, `oban_queues/0`, `migration_module/0`,
  `required_modules/0`, and Hex catalog search `phoenix_kit_` all exist as
  described.
- `KnownPackages.derive_module_atom/1` does produce `PhoenixKitMediaTimeline`.

**The “do not” list is the right list**, especially: do not HEEx 50k `<img>`s,
do not layout on the server on resize, do not put `<video>` in cells, do not
hardcode dimension names, do not forget `system_managed = false`.

**Default image dimensions are aspect-preserving**, which the plan does not
quite say. `maintain_aspect_ratio` defaults to `true`, and in that mode
`VariantGenerator` resizes by width only. So seed sizes `thumbnail` 150×150
and `small` 300×300 are *not* square crops unless an admin turns the flag
off. That is why a justified cell can show `thumbnail` / `small` at all. If
someone sets `maintain_aspect_ratio: false` on those rows, the timeline will
look cropped. Resolve variants by “smallest enabled *aspect-preserving*
image dimension,” not by name.

---

## Close these two decisions now

### 1. Date extraction belongs in PhoenixKit core

The open question in Stage 0 should not stay open.

Capture date is a column on the `phoenix_kit_files` table, filled by
`ProcessFileJob`, indexed next to `user_uuid`, and needed by anything that
wants “when was this taken.” That is Storage, not timeline. An external
`migration_module/0` *can* add a column — `PhoenixKit.Migrations.Repair`
treats extra columns as info-only, it will not drop them — but it is a bad
home:

- The next PhoenixKit version that adds `taken_at` itself will collide.
- `mix phoenix_kit.doctor` will keep reporting
  `column:phoenix_kit_files.taken_at` as an extra object.
- The package cannot hook ingest cleanly. `ProcessFileJob` has no plugin
  API. You either patch core or you subscribe to
  `{:phoenix_kit_file_processed, uuid}` and do a second pass, which races
  the first paint and double-reads the original.
- Backfill of existing originals is a storage job on the `file_processing`
  queue.

**Do this:** Stage 0 is a PhoenixKit PR (capture-date columns, EXIF/ffprobe
extraction, backfill, partial index). The package declares
`required_modules: ["storage"]` and a minimum `phoenix_kit` version.
Buckets, window API, hook, and UI stay in `phoenix_kit_media_timeline`.

Do not add `exiftool` as a new system dependency. PhoenixKit already shells
out to ImageMagick `identify` and `ffprobe`.
`identify -format '%[EXIF:DateTimeOriginal]'` and ffprobe
`format_tags=creation_time` are enough for v1. `exiftool` is more complete
(`OffsetTimeOriginal`, MakerNotes, QuickTime `creation_date`) and can come
later.

### 2. Do not prototype as `Fotki.Media.Timeline`

This repo is already the package. Fotki is `/www/app`. “Build in the app,
extract later” is how Fotki-specific assumptions leak into the contract, and
extraction is not mechanical once the hook talks to app JS, app routes, and
app PubSub.

Path-dep the package into Fotki from commit one. Validate 10k / 100k against
a Fotki seed. The JS hook’s two JSON shapes are the seam; that still holds.

---

## The data model gap: calendar months need a local date

This is the change to make before writing any grid code.

The plan stores `taken_at :utc_datetime` and buckets by year/month. EXIF
`DateTimeOriginal` is almost always a **naive local time** with no zone.
Video `creation_time` is usually UTC. If you coerce everything to UTC and
then `GROUP BY date_trunc('month', taken_at)`, a photo taken 31 July 23:00
in PDT becomes 1 August UTC and lands in the wrong month. Immich and
PhotoStructure both ended up with a local datetime plus an offset for this
reason.

Also, the fallback “file ctime/mtime” is weak here. Originals live in local
disk or S3; `LastModified` is upload time, i.e. the same information as
`inserted_at`. For a camera dump, the filename (`IMG_20180701`,
`PXL_20240315_081100`) is a better third source than mtime.

Suggested columns on `phoenix_kit_files` (in core):

| column | role |
|---|---|
| `taken_at` | UTC instant, for ordering and “jump to this moment” |
| `taken_on` | local **date**, for month/day buckets and headers |
| `taken_at_source` | `:exif` / `:filename` / `:inserted_at` / `:manual` |

Resolution order: EXIF (with `OffsetTimeOriginal` when present) → filename
date → `inserted_at`. Store the source so a later backfill can overwrite
inferred dates without clobbering a user correction.

Without `taken_on`, Stage 1 month headers will be wrong for a real library.
That is not a v2 polish item.

---

## Gaps that will hurt if they stay implicit

### Window size

The index payload is fine (a few hundred month buckets). The **section
window** is not.

A holiday month of 20k items at ~250 bytes each is ~5MB through the LiveView
socket. 412 items is ~100KB and acceptable. The plan says fat months split
into days, but never says when, and still fetches by `"section": "2018-07"`.

**Fetch windows by day. Keep months for the scrubber index.** A day is
typically tens to a few hundred tiles. Put a hard cap on a window (e.g. 500)
and subdivide if a single day exceeds it. Do not wait for Stage 5 to invent
this — it is a load-bearing part of the contract.

LiveView `push_event` is fine for those windows. A separate HTTP JSON
endpoint is only worth it if a day is still huge.

### The query filter is one predicate short

The mandatory `WHERE` is right about Tessera and trash, and missing the
thing that will show grey tiles forever:

```sql
AND status = 'active'
AND width > 0 AND height > 0
```

Processing/failed rows have no variants. Zero dimensions blow up `ar` and
the layout. Historical `file_type = 'image'` on a `.mov` is already called
out — those rows often have no `width`/`height`, so the dimension predicate
also saves you there.

`edit_state` in `pending`/`failed` still occupies the same uuid and should
stay in the grid (the file controller already serves a placeholder). Do not
copy the `is_nil(edit_state)` filter from `storage.ex:4019`; that is a
different listing.

Index the way you query (on the `phoenix_kit_files` table, in core):

```sql
CREATE INDEX ... ON phoenix_kit_files (user_uuid, taken_on DESC, taken_at DESC)
WHERE system_managed = false
  AND trashed_at IS NULL
  AND parent_file_uuid IS NULL
  AND file_type IN ('image', 'video')
  AND status = 'active';
```

A btree on `(user_uuid, taken_at DESC)` without the partial predicate will
still scan Tessera children for that user.

### Do not materialize buckets in v1

At 100k rows, `GROUP BY taken_on` against that index is cheap. A projection
you increment on ingest / trash / restore / date change is where the subtle
bugs live, and a full recompute per owner on every upload will stampede Oban.

Start with live aggregation. Materialize only after you measure. If you do
precompute, debounce per owner.

### PubSub is “the bucket of `taken_on`,” not “today”

`{:phoenix_kit_file_processed, file_uuid}` already exists. Subscribe to it.
After reload: if `taken_on` is 2016-03-12, update March 2016 (and that day),
not “today.” Inserting a 2016 photo at the front of today is a visible bug
the first time someone imports a camera dump.

Same event is how a processing row appears once it becomes `active`.

### Scope is ahead of the product

The component already takes `{:user, uuid} | {:album, id} | {:share, token}`.
PhoenixKit has folders, not albums, and no library share tokens. §1 says
personal library / album / shared link is the product; Stages 1–5 never
mention the last two.

v1 scope: `{:user, uuid}` only, maybe `{:folder, uuid}` if MediaBrowser
folders are the album. Shares are a later table and a later authorization
path. Leaving them in the public component contract now means extracting a
published API you will regret.

### Square heights are exact; justified heights are not

`sum_aspect * target_row_height / container_width` ignores gutters, the
month header, and the leftover last row. For **square** N-columns, height is
`ceil(count / cols) * (cell + gap) + header` and does not need tombstone
refinement. That is why Stage 1 can validate the contract without Stage 2.

Say that explicitly so Stage 2 is not treated as a prerequisite for the 10k
test.

On resize (sidebar, rotate, density slider), recompute **all** section
heights and restore position by an **anchor item**, not by `scrollTop`
pixels. Pixel correction inside a section is not enough when every section
above you also changed.

### The JS hook owns tiles; ImageSet does not

`PhoenixKit.Modules.Shared.Components.ImageSet` is a LiveView `<picture>`
with srcset. Putting that in HEEx for visible tiles fights the recycling
pool. The hook should set `img.src` (and maybe `srcset`) on pooled nodes.
`loading="lazy"` plus a pool of 80–120 is correct; `decoding="async"` too.

Signed URLs from `URLSigner` are not expiring (4-char MD5 of `uuid:variant`
+ secret). That is existing PhoenixKit design, and it is convenient here —
you can put them in the window JSON. They do not check the current user, so
the **window API** must. Do not skip the scope check because the thumb URL
is “unguessable.”

`js_sources/0` wants a **prebuilt** bundle in `priv/`. The package needs its
own esbuild (or equivalent) that emits
`priv/static/assets/phoenix_kit_media_timeline.js` with a unique global,
e.g. `PhoenixKitMediaTimelineHooks`, and hook names that cannot collide with
core (`PhotoTimeline`, not `Grid`). That is a Stage 1 deliverable, not a
packaging afterthought.

---

## Smaller notes

- **Viewer.** `on_open` should emit to the existing MediaViewer /
  MediaCanvasViewer. PhotoTimeline should not grow a lightbox. Stage 4
  “restore position when returning from the viewer” needs a URL or a
  return-to id (`?at=<file_uuid>` or the section id), otherwise
  back-from-viewer is a scroll reset.
- **Selection** is in the component contract and in no stage. Either drop
  `on_select` from v1 or add a thin Stage 1.5 (shift-click range, selection
  count). Drop it until there is a bulk action.
- **Permissions** are listed as “the callback exists” and never specified.
  Minimum: owner sees their library; admin may see any user; nobody else.
  Encode that in `permission_metadata/0` before the first route ships.
- **i18n.** PhoenixKit is multilingual. Month headers and scrubber labels
  go through Gettext. The hook should receive already-formatted labels, not
  English month names.
- **Capacity gates.** Make them acceptance tests, not comments: Stage 1
  does not ship until a 10k square grid jumps to a random month without
  dropping frames in Chrome and Safari, with the DOM node count bounded.
  Stage 3 does not ship until a 100k justified library does the same.
  Safari is why Immich had a WASM round two — square-first is the right
  order.
- **Flickr `justified-layout`** is old CommonJS. For Stage 3, port the
  small algorithm (or Google’s FlexLayout with shrink/stretch) into the
  hook. Reach for `@immich/justified-layout-wasm` only after a measured
  layout cost on a fat month. WASM in the PhoenixKit asset compiler is a
  real cost (Safari, prebuild, CSP).
- **Testing.** A synthetic 10k/100k seed with a realistic aspect mix (lots
  of 4:3 and 3:2, some 9:16, some panoramas) belongs in Fotki or in the
  package’s test support. The hook needs a unit test for prefix-sum jump
  and scrollTop correction; browser tests for “open viewer, return, still
  on the same tile.”
- **Empty / first-run.** Zero photos, “still processing today’s upload,”
  backfill in progress. The plan is silent on these and they are the first
  thing a Fotki user will see.
- **Catalog publishing.** `meta.links.GitHub` and
  `hex_docs_icon_name: photo` are correct and easy to forget. Keep them on
  the release checklist.

---

## Suggested stage trim

| Stage | Keep | Change |
|---|---|---|
| 0 | Capture date, extraction, backfill, index, window API | Do it in PhoenixKit core, as a column (plus `taken_on` / `taken_at_source`) on the `phoenix_kit_files` table. Filter `status = 'active'`. Windows are days, index is months. No bucket table yet. |
| 1 | Square grid, section virtualization, month header, date list jump | Path-dep package in Fotki. 10k gate. `{:user, uuid}` only. |
| 2 | Tombstones + height correction | Only needed once justified (or variable row height) exists. Skip for square. Handle **resize + anchor restore** here whenever it happens. |
| 3 | Justified | Own JS first; WASM only if measured. |
| 4 | Scrubber + viewer return | Fine. Date-list jump in Stage 1 is the MVP. |
| 5 | Density, prefetch, fat-day split | Pull “fat day split” forward into Stage 0/1. Prefetch adjacent days in Stage 1 already, or jump-to-date shows a blank month. |

Faces / map / memories stay out. Good.

---

## One-sentence counter-recommendation

Same sentence as the plan’s §7, with a sharper Stage 0: **put capture date
on Storage’s `phoenix_kit_files` table in PhoenixKit core, put the section
index and the scrubbable grid in `phoenix_kit_media_timeline`, and do not
publish a scope or a bucket table you have not used against a 10k library.**
