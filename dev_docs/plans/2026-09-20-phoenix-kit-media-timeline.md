# Photo / Video Timeline for PhoenixKit

Design note: a scrubbable media library in the spirit of Apple Photos /
Google Photos, built on Elixir, Phoenix LiveView and PhoenixKit.

Created: 2026-09-20
Updated: 2026-09-20 — revision 2. Delivery shape and name decided (§5.1);
all PhoenixKit facts verified against the 2.32.1 sources; review at
`dev_docs/reviews/2026-09-20-phoenix-kit-media-timeline.md` incorporated
(capture date model, window sizing, query filter, packaging deliverable,
stage trim).

> **Renamed 2026-09-21.** The package is now `phoenix_kit_photos`
> (`PhoenixKitPhotos`, module key `photos`), rescoped as a Photos-class library
> with the timeline as its first view. The name and scope in §5.1 are superseded
> by [`2026-09-21-phoenix-kit-photos.md`](2026-09-21-phoenix-kit-photos.md),
> which also maps every old name to its new one. The rest of this plan stands.

---

## 0. Naming, so this plan is not misread

`phoenix_kit_files` is **not a module and not a Hex package**. It is the
Postgres table for original uploads, owned by PhoenixKit core's always-on
Storage module.

| Name | What it is |
|---|---|
| `phoenix_kit` | Hex package (core), 2.32.1 in Fotki |
| `PhoenixKit.Modules.Storage` | Elixir module, `module_key/0` = `"storage"` |
| `PhoenixKit.Modules.Storage.File` | Ecto schema |
| `phoenix_kit_files` | the SQL table that schema maps to |
| `phoenix_kit_media_timeline` | the package this plan proposes |

So "add `taken_at` to `phoenix_kit_files`" means: add a column to Storage's
files table **in PhoenixKit core**. Fotki created that table via
`priv/repo/migrations/20260919235130_add_phoenix_kit_tables.exs` →
`PhoenixKit.Migrations.up/1`. There is no `PhoenixKitFiles` module to depend on.

---

## 1. Why this exists at all

What's needed is not "a gallery for 200 wedding photos" but a component where
a person opens **their entire media library spanning decades** and can:

- browse calmly, day by day;
- grab the scrollbar / scrubber and jump to March 2016;
- not kill the browser tab at 50,000–200,000 files;
- open a photo or a clip without losing their place in the feed.

This is the core of photo/video hosting and sharing: personal library, album,
shared link. MediaBrowser already sits next to it (folders, picker, upload) —
that is a **different** widget.

---

## 2. What the brief was

The original request:

- stack: Elixir, Phoenix, PhoenixKit;
- UX like Apple Photos / Google Photos: the whole history plus the ability to
  "scroll through" to any moment;
- there were articles by Google engineers somewhere about how hard this grid is;
- browsers have improved since then and libraries now exist — what should we
  take off the shelf, and what do we write ourselves?

Designing faces / map / memories / AI search up front was not required.
First, an honest timeline.

---

## 3. What we found

### 3.1. The article everyone remembers

The primary source is Antin Harasymiv, *Building the Google Photos Web UI*
(Google Design, 2018). There are retellings and later analyses of the same model.

Google pursued four goals simultaneously:

1. **Scrubbable Photos** — jump to any point in the archive.
2. **Justified layout** — full-width feed, aspect ratios preserved, no
   cropping into squares.
3. **60fps** across hundreds of thousands of photos.
4. **Instantaneous feel** — as little waiting on loads as possible.

The article's key conclusion: ordinary infinite scroll **does not work**.
Pagination and "load 20 more" never give you a known page height, so the
scrollbar is not a coordinate in time.

Their scheme:

- the collection is cut into **sections** (a month, or a smarter cluster);
- on startup only sections and counts go over the wire — a tiny payload even
  for millions of photos;
- the client **estimates the height** of each section and puts down a placeholder;
- metadata for specific photos is requested when a section approaches the viewport;
- only visible tiles plus a buffer live in the DOM;
- previews are layered: tiny thumb → preview → original.

The same ideas were repeated later in write-ups on infinite scroll / tombstones /
DOM recycling, and in the Google Photos mobile architecture (metadata held
locally, grid paged, scrubber driven by a secondary date index).

### 3.2. How this looks in the wild today

- **Apple Photos / Google Photos** — a continuous feed plus a date overlay plus
  a side scrubber going year → month. In Google's version, scrubber speed
  depends on how far left the finger is dragged (coarse / fine mode). The
  2025–2026 redesigns removed daily headers in places, and users complained
  immediately: without date anchors the feed turns to mush.
- **Immich** — the closest open-source reference. TimelineManager, month/day
  groups, virtual scroll, justified gallery, WASM layout
  `@immich/justified-layout-wasm`, pinch-zoom for grid density, video posters.
  The stack is Svelte, not LiveView, but the **data model** is exactly what we need.
- **PhotoStructure / LibrePhotos / mPhotos** — they confirm the same thing:
  a virtual grid plus precomputed previews in several sizes. Without a preview
  pyramid, "smart scrolling" is pointless.

### 3.3. Off-the-shelf pieces in the ecosystem

| Problem | What exists | Comment |
|---|---|---|
| Justified geometry | `flickr/justified-layout`, `@immich/justified-layout-wasm` | Take the algorithm, write the wiring |
| Virtual list/grid | TanStack Virtual, virtua | Strong in React/Vue/Svelte. Expensive to drag into plain LiveView |
| Classic galleries | Justified Gallery, PhotoSwipe, LightGallery | An album of tens to hundreds of photos, not "18 years of a life" |
| CSS acceleration | `content-visibility: auto` + `contain-intrinsic-size` | Helps at hundreds to a couple thousand blocks. Does not replace scrubbable-timeline geometry |
| LiveView infinite scroll | `stream` + `phx-viewport-top/bottom` | Perfect for a feed. Breaks jump-to-year |

Market verdict: there is no ready-made "Google Photos component". There is
layout math, and virtualizers belonging to other frameworks.

### 3.4. What already exists in PhoenixKit

This matters: the timeline does not start from zero. Verified against
`phoenix_kit` 2.32.1 (Hex).

What's there:

- `PhoenixKit.Modules.Storage.File` (`lib/modules/storage/schemas/file.ex`) —
  mime, `file_type` (`image` / `video` / `document` / `archive`),
  `width`/`height`, `duration`, `metadata` (jsonb), checksum, `trashed_at`,
  owner. Keys are `uuid`, `user_uuid`, `folder_uuid`, and on instances
  `file_uuid` — **not** `owner_id` / `file_id`.
- `FileInstance` — the file's variants. `variant_name` is a free-form string,
  and the variants themselves are rows in the `phoenix_kit_dimensions` table
  (`schemas/dimension.ex`), configurable per installation. The default seeds
  (`storage.ex:735`) do give `thumbnail`, `small`, `medium`, `large` for
  images and `360p`, `720p`, `1080p`, `video_thumbnail` for video — but these
  are database rows, not an enum, and an admin can rename or delete them.
- `ImageSet` — `<picture>` + srcset (AVIF/WebP/JPEG).
- `MediaBrowser` — folders, upload, search, picker (4,162 lines).
- `MediaGallery` — selecting and ordering a set of images for a form.
- External-module infrastructure: `PhoenixKit.Module`,
  `PhoenixKit.ModuleRegistry`, `PhoenixKit.ModuleDiscovery`,
  `PhoenixKit.KnownPackages` — see §5.1.
- Publishing / Posts can already attach files by file uuid.

What's missing — and it is more than "one artifact and one widget":

- **`taken_at` does not exist, and EXIF is not extracted at all.**
  `ProcessFileJob.extract_image_metadata/1`
  (`workers/process_file_job.ex:245`) writes only `width`, `height`, `format`.
  For video (`:277`) it writes `width`, `height`, `duration` via ffprobe, with
  no `creation_time`. The `metadata` field is documented as "EXIF, codec info"
  (`schemas/file.ex:36`), but nothing writes EXIF into it. Worse,
  `ImageProcessor.sanitize/3` (`services/image_processor.ex:309`) passes
  `-strip` and deliberately destroys EXIF (the rationale being GPS leakage from
  a bug-report screenshot). That function is not on the general ingest path
  today, but anything that adopts it kills the capture date irreversibly.
- **There is no index for the timeline query.** `phoenix_kit_files` has btree
  indexes on `inserted_at`, `user_uuid`, `file_type`, `status`, `trashed_at`
  (`migrations/postgres/v135.ex:2486` onward). There is no composite
  `(user_uuid, taken_at DESC)`.
- **The files table is not a clean list of assets.** `system_managed = true`
  covers Tessera DZI tile pyramids (thousands of rows per single image),
  children linked by `parent_file_uuid`, and the pre-edit original, which after
  an edit lives on as a system-managed child (`original_file_uuid`, V195).
  Without a filter, a single edited photo inflates its month's count, and tiles
  of tiles crawl into the grid.
- **`file_type` can lie on older rows.** `reconcile_file_type/3`
  (`storage.ex:3941`) was added as a defence precisely because an external
  module stored `.mov` and `.mp3` as `"image"`. New uploads are cleaned up;
  historical rows are not.
- The server-side **timeline index** and the **PhotoTimeline** UI widget.

Two facts that shape the query and the tiles:

- `status` is one of `processing` / `active` / `failed` / `trashed`
  (`schemas/file.ex:265`). Non-active rows have no variants — they render as
  grey tiles forever if they reach the grid.
- **Default image dimensions preserve aspect ratio.**
  `maintain_aspect_ratio` defaults to `true` (`schemas/dimension.ex:87`), and
  in that mode `VariantGenerator` resizes by width only
  (`variant_generator.ex:501`). So the seeds `thumbnail` 150×150 and `small`
  300×300 are *not* square crops, which is why they can fill a justified cell
  at all. If an admin turns the flag off on those rows, the timeline looks
  cropped — so resolve variants by "smallest enabled **aspect-preserving**
  image dimension", not by name.

---

## 4. Why LiveView streams are not the answer

`phx-viewport-bottom` + `stream` with a `limit` produces a Twitter feed:

- a window of N elements is held in the DOM;
- scroll to the bottom, append, drop from the top;
- there is no height for "the whole history";
- the scrollbar lies;
- "open July 2014" has nowhere to map to.

For Photos, the scrollbar has to be a **map of time**. Which means the client
must know at least an estimate of every section's height **before** the photos
themselves arrive.

LiveView still remains:

- the source of truth for permissions, sharing, uploads, trash;
- the transport for windows ("give me section 2018-07");
- the realtime bus (PubSub: a just-uploaded photo appears under "today").

Geometry, tile recycling and the scrubber live in a JS hook.

---

## 5. The proposal

Our own library — **yes, but a narrow one**.
Not another virtuoso, and not a fork of Immich.

Take off-the-shelf code only where it is boring and stable: the justified
algorithm, and the file-variant pipeline that already exists.

### 5.1. Delivery shape and name

Decided: not a generic library for all of Hex, but an **external PhoenixKit
module** in a separate package, `phoenix_kit_media_timeline`.

Why not generic:

- the timeline's value rests on the preview pipeline, ingest, permissions,
  sharing and trash. That is 80% of the work, and a generic package cannot
  provide any of it — it would ship a grid with a note saying "bring your own
  EXIF, your own four preview sizes and your own windowed query";
- nor can a generic package get those from PhoenixKit: `phoenix_kit` pulls
  ~45 transitive dependencies (ex_aws ×5, ueberauth ×4, oban, bcrypt, swoosh,
  tessera, rustler). Nobody will install that to get a photo grid.

Why a PhoenixKit module — the external-module infrastructure is already built
there. It is not a convention, it is a working mechanism:

- `PhoenixKit.Module` (`lib/phoenix_kit/module.ex:146`) — a behaviour with ~40
  callbacks. Every one we need exists: `migration_module/0` (our own versioned
  migration alongside core), `js_sources/0` and `css_sources/0` (`:355`, `:307`
  — the hook ships through PhoenixKit's asset compilers, which this application
  already runs), `oban_queues/0` (`:408` — the backfill/reindex queue),
  `route_module/0`, `permission_metadata/0`, `admin_tabs/0`, and
  `required_modules/0` to declare a hard dependency on `"storage"`;
- `PhoenixKit.ModuleDiscovery` — auto-registration by scanning beam attributes
  of dependencies that depend on `:phoenix_kit`. Zero config for the consumer,
  just a line in `mix.exs`;
- `PhoenixKit.KnownPackages` — the admin module catalog searches Hex with
  literally `?search=phoenix_kit_&sort=name` (`known_packages.ex:214`). A
  package outside that namespace is **invisible** in the catalog. That settles
  the naming question by itself.

The precedent already exists: `phoenix_kit_templates` is a separate Hex
package, and `phoenix_kit_hello_world` is the documented starter template.

**The name.** `gallery` is taken: `PhoenixKitWeb.Components.MediaGallery`
already exists and means "select, order and remove a set of images" — exactly
the widget the timeline must not be confused with (§5.2). `grid` describes one
of the layout modes (`:square`), not the package, and MediaBrowser renders a
grid too. Bare `timeline` inside PhoenixKit already reads as an event log —
`Components.Core.EventTimelineItem` renders email event timelines, and a
"Timeline" entry next to Activity and Audit Log is ambiguous. `media_*` is the
established core namespace (`media_browser`, `media_gallery`, `media_viewer`,
`media_canvas_viewer`, `media_thumbnail`).

Hence:

| | value |
|---|---|
| Hex package | `phoenix_kit_media_timeline` |
| Namespace (`derive_module_atom`) | `PhoenixKitMediaTimeline` |
| `module_key/0` | `media_timeline` |
| Admin label (`humanize_key`) | Media Timeline |
| Setting | `media_timeline_enabled` |
| Route prefix | `media-timeline` (or claim `photos` via `reserved_route_prefixes/0`) |
| Component | `PhoenixKitMediaTimeline.Components.PhotoTimeline` |

When publishing:

- fill in `meta.links.GitHub` explicitly — otherwise `github_url_for/2`
  substitutes a nonexistent `github.com/BeamLabEU/<package>`;
- put the marker `hex_docs_icon_name: photo` in the package description, or the
  catalog icon will be the default puzzle piece.

### 5.1.1. Order of work

**Do not prototype as `Fotki.Media.Timeline`.** This repo is already the
package; Fotki is `/www/app`. "Build in the app, extract later" is how
Fotki-specific assumptions leak into the contract, and extraction stops being
mechanical the moment the hook talks to app JS, app routes and app PubSub.

Path-dep the package into Fotki from commit one:

```elixir
{:phoenix_kit_media_timeline, path: "../phoenix_kit_media_timeline"}
```

Validate 10k then 100k against a Fotki seed. The JS hook's two JSON shapes
(§5.3) are the seam, and that still holds.

The JS hook knows nothing of Elixir, Ecto or PhoenixKit — only those two JSON
contracts. It is the one genuinely portable part, and its boundary must hold
from day one. Do not erect an Elixir "source" behaviour in advance — the
package boundary is already the seam.

**Stage 0 goes upstream, not into this package.** Capture date is a column on
Storage's files table, filled by `ProcessFileJob`, indexed next to
`user_uuid`, and wanted by anything asking "when was this taken". That is
Storage, not timeline. An external `migration_module/0` *can* add a column
(`Migrations.Repair` only raises `:info` findings for extra columns,
`repair.ex:419`, and will not drop them) but it is the wrong home:

- the next PhoenixKit release that adds `taken_at` itself collides;
- `mix phoenix_kit.doctor` reports `column:phoenix_kit_files.taken_at` as an
  extra object forever;
- `ProcessFileJob` has no plugin API, so the package would either patch core
  anyway or subscribe to `{:phoenix_kit_file_processed, uuid}` and do a second
  pass — racing first paint and re-reading the original twice;
- backfill of existing originals is a storage job on the `file_processing`
  queue (`oban_queues.ex:73`).

So Stage 0 is a PR against PhoenixKit core. To avoid blocking development on
someone else's review cadence, work against a **local fork path-dep**
(`{:phoenix_kit, path: "../phoenix_kit"}`) carrying the same migration, submit
the PR in parallel, and swap to `{:phoenix_kit, "~> 2.33"}` once it lands.
The package then declares `required_modules: ["storage"]` plus that minimum
core version. Buckets, window API, hook and UI stay here.

Do not add `exiftool` as a new system dependency for v1. PhoenixKit already
shells out to ImageMagick `identify` and to `ffprobe`;
`identify -format '%[EXIF:DateTimeOriginal]'` and ffprobe
`format_tags=creation_time` cover v1. `exiftool` is more complete
(`OffsetTimeOriginal`, MakerNotes, QuickTime `creation_date`) and can come later.

### 5.2. Component contract

```elixir
<.live_component
  module={PhoenixKitMediaTimeline.Components.PhotoTimeline}
  id="library"
  scope={{:user, user.uuid}}   # v1: this only
  layout={:square}             # v1: :square; :justified lands in Stage 3
  columns={5}
  on_open="open_asset"
/>
```

**The published v1 contract is deliberately smaller than §1's product.**
`{:album, id}` and `{:share, token}` are not in it: PhoenixKit has folders,
not albums, and there are no library share tokens — shares are a later table
and a later authorization path. Stages 1–5 never touch either. Shipping them
in the public component contract now means withdrawing a published API later.

If MediaBrowser folders turn out to be the album, `{:folder, uuid}` is the
natural second scope, and it can be added without a breaking change.

`on_select` is likewise held back. Selection appears in no stage and has no
bulk action behind it; add it (with shift-click range and a selection count)
only once something consumes a selection.

Three different widgets, never to be mixed:

- **MediaBrowser** — file work (folders, ingest, search);
- **MediaGallery** — selection and ordering of an image set for a form;
- **PhotoTimeline** — a person's life by capture date.

### 5.3. Server model

#### Capture date needs a local date, not just a UTC instant

This is the change to make before any grid code exists.

EXIF `DateTimeOriginal` is almost always a **naive local time** with no zone.
Video `creation_time` is usually UTC. Coerce everything to a single
`taken_at :utc_datetime` and then `GROUP BY date_trunc('month', taken_at)`,
and a photo taken 31 July at 23:00 PDT becomes 1 August UTC and lands in the
wrong month. Immich and PhotoStructure both converged on a local datetime
plus an offset for exactly this reason.

Columns on `phoenix_kit_files`, in core (§0):

| column | role |
|---|---|
| `taken_at` | UTC instant — ordering, and "jump to this moment" |
| `taken_on` | local **date** — month/day buckets and headers |
| `taken_at_offset` | UTC offset in seconds when known — lets the viewer show the original local time |
| `taken_at_source` | `:exif` / `:filename` / `:inserted_at` / `:manual` |

Resolution order:

1. EXIF `DateTimeOriginal` / `CreateDate`, with `OffsetTimeOriginal` when present;
2. otherwise a date parsed from the filename (`IMG_20180701`,
   `PXL_20240315_081100`);
3. otherwise `inserted_at`.

Filename beats file mtime here. Originals live on local disk or in S3, where
`LastModified` is upload time — the same information `inserted_at` already
carries. For a camera dump the filename is genuinely better evidence.

`taken_at_source` is what lets a later backfill overwrite an inferred date
without clobbering a user's manual correction.

Without `taken_on`, Stage 1's month headers are wrong for any real library.
That is not v2 polish.

#### The index

A cheap aggregation, not a list of every id.

```elixir
%{
  user_uuid: ...,
  year: 2018,
  month: 7,
  count: 412,
  first_taken_on: ~D[2018-07-01],
  last_taken_on: ~D[2018-07-31],
  sum_aspect: 548.2
}
```

The index bucket is a calendar month — a few hundred buckets for a library of
any size, which is what the scrubber track needs.

**Do not materialize buckets in v1.** At 100k rows a `GROUP BY taken_on`
against the partial index below is cheap. A projection incremented on ingest /
trash / restore / date change is where the subtle bugs live, and a full
recompute per owner on every upload will stampede Oban. Start with live
aggregation; materialize only after measuring, and debounce per owner if you do.

#### The mandatory filter

Every query — index and window alike:

```sql
WHERE system_managed = false
  AND trashed_at IS NULL
  AND parent_file_uuid IS NULL
  AND file_type IN ('image', 'video')
  AND status = 'active'
  AND width > 0 AND height > 0
```

`status = 'active'` keeps processing and failed rows out: they have no
variants and render as grey tiles forever. The dimension predicate keeps
`ar` from blowing up the layout, and incidentally rescues the historical
`file_type = 'image'` rows that are really `.mov` — those usually have no
`width`/`height`.

Note what is *not* filtered: `edit_state` in `pending` / `failed` occupies the
same uuid and belongs in the grid, because `FileController` already serves a
placeholder for it. Do not copy the `is_nil(edit_state)` predicate from
`storage.ex:4019` — that is a cross-user dedup lookup, a different query.

Index the way you query, on `phoenix_kit_files` in core:

```sql
CREATE INDEX phoenix_kit_files_timeline_index
ON phoenix_kit_files (user_uuid, taken_on DESC, taken_at DESC)
WHERE system_managed = false
  AND trashed_at IS NULL
  AND parent_file_uuid IS NULL
  AND file_type IN ('image', 'video')
  AND status = 'active';
```

A plain btree on `(user_uuid, taken_at DESC)` without the partial predicate
still scans that user's Tessera children.

#### Fetch windows by day; keep months for the index

The index payload is fine at month granularity. The **window** is not. A
holiday month of 20k items at ~250 bytes each is ~5MB through the LiveView
socket; 412 items is ~100KB and perfectly acceptable. "Fat months split into
days" cannot be a Stage 5 idea when the fetch key is `"2018-07"` — it is a
load-bearing part of the contract.

So: the scrubber index is monthly, the window is a **day**, and a day is
typically tens to a few hundred tiles. Put a hard cap on a window (500 items)
and subdivide further if a single day exceeds it.

LiveView `push_event` is an adequate transport for windows of that size. A
separate HTTP JSON endpoint is only worth it if a single day is still huge.

Startup payload:

```json
{
  "total": 184203,
  "sections": [
    {"id": "2018-07", "count": 412, "sum_aspect": 548.2, "days": 19},
    {"id": "2018-08", "count": 91,  "sum_aspect": 120.4, "days": 7}
  ]
}
```

Section window (one day):

```json
{
  "section": "2018-07-14",
  "items": [
    {
      "id": "...",
      "taken_at": "...",
      "w": 4032,
      "h": 3024,
      "ar": 1.333,
      "thumb": "/file/.../thumbnail",
      "preview": "/file/.../small",
      "kind": "image"
    }
  ]
}
```

The LiveView socket holds the index plus the current window. Not the whole library.

The index is updated on ingest / trash / restore / date change — by live
re-aggregation in v1 (see above), not a projection.

**Realtime keys off `taken_on`, not "today".** `{:phoenix_kit_file_processed,
file_uuid}` already exists (`storage.ex:179`) — subscribe to it, reload the
row, and update the bucket its `taken_on` names. If that is 2016-03-12, March
2016 is what changes. Inserting a 2016 photo at the front of today is a
visible bug the first time somebody imports a camera dump. The same event is
how a `processing` row enters the grid once it turns `active`.

### 5.4. Client model

The hook owns the geometry:

1. Estimate a section's height from `count`, container width, target row height
   and `sum_aspect` (or from the square-grid formula).
2. Prefix-sum of heights → an honest `scrollHeight` for the entire library.
3. Jump to date = binary search over the prefix-sum + `scrollTo`.
4. Intersection / scroll position → which sections to materialize.
5. For visible sections — justified (or square) layout and an absolutely
   positioned set of tiles.
6. Recycle a pool of DOM nodes (~80–120); do not create/destroy every frame.
7. If a section's height changed after exact layout, correct `scrollTop` by the
   delta, or the page jumps.

**Square heights are exact; justified heights are estimates.** For an
N-column square grid the height is
`ceil(count / cols) * (cell + gap) + header` — no tombstone refinement needed,
which is precisely why Stage 1 can validate the contract without Stage 2.
The justified estimate `sum_aspect * target_row_height / container_width`
ignores gutters, the month header and the ragged last row, so it is Stage 3
that makes height correction mandatory, not Stage 1.

**On resize** — sidebar toggle, rotation, density slider — recompute *all*
section heights and restore position by an **anchor item**, not by `scrollTop`
pixels. Pixel correction within one section is not enough when every section
above the viewport changed too.

Preview layering:

| State | PhoenixKit variant |
|---|---|
| Fast scroll, tombstone just became a tile | `thumbnail` |
| Tile stably in viewport | `small` |
| Viewer / share preview | `medium` / `large` |
| Video in the grid | `video_thumbnail` only, never `<video>` |

Do not hardcode variant names: they are rows in `phoenix_kit_dimensions` and
differ per installation. Resolve by **smallest enabled aspect-preserving image
dimension** (§3.4) with a fallback — `small` may not be configured, may be
renamed, or may have `maintain_aspect_ratio: false` and crop.

**The hook owns the tiles; `ImageSet` does not.**
`PhoenixKit.Modules.Shared.Components.ImageSet` is a LiveView `<picture>` with
srcset — putting it in HEEx for visible tiles fights the recycling pool. The
hook sets `img.src` (and `srcset` where useful) on pooled nodes. `ImageSet`
remains the right thing for the viewer.

`loading="lazy"` and `decoding="async"` are mandatory but do not replace
virtualization: the browser still must not hold 50k `<img>` elements.

**Signed URLs do not authorize.** `URLSigner` tokens are the first 4 hex
characters of an MD5 over `uuid:variant` plus `secret_key_base`
(`url_signer.ex:152`) and never expire. That is existing PhoenixKit design and
convenient here — the URLs can go straight into the window JSON. But they do
not check the current user, so **the window API must**. Never skip the scope
check on the grounds that a thumbnail URL is unguessable.

### 5.5. Scrubber

A separate control on the right; the native scrollbar is not the only UI.

- the track = the whole history;
- year labels;
- on drag, the current month/day as an overlay on the grid;
- coarse movement by years, fine by months (the "drag the finger sideways to
  slow down" gesture can be reproduced).

A list of months as a fallback jump (like the date picker in mPhotos) is a
cheap MVP ahead of a proper scrubber.

### 5.6. What not to do

- Do not render tens of thousands of `<img>` through HEEx "because streams".
- Do not compute justified layout on the server on every resize.
- Do not put video elements into grid cells.
- Do not build the first release on faces / map / memories.
- Do not substitute the timeline for MediaBrowser or vice versa.
- Do not expect `content-visibility` to replace section height estimation.
- Do not hardcode variant names — they are configurable per installation.
- Do not forget `system_managed = false`, or Tessera tiles will land in the feed.
- Do not teach the JS hook anything about PhoenixKit: its contract is the two
  JSON shapes from §5.3.
- Do not fetch a window by month — a fat month is megabytes (§5.3).
- Do not trust a signed thumbnail URL as authorization.
- Do not put `ImageSet` in a recycled tile.
- Do not bucket by `date_trunc('month', taken_at)` on a UTC instant.

### 5.7. The JS bundle is a Stage 1 deliverable

`js_sources/0` does not compile the package's JavaScript — it declares a
**prebuilt** bundle that already sits in the app's `priv/`
(`module.ex:307-384`). So the package needs its own esbuild (or equivalent)
emitting `priv/static/assets/phoenix_kit_media_timeline.js`.

Two collision rules, both real:

- `:global` must be unique across every module. Use
  `PhoenixKitMediaTimelineHooks`.
- **Hook names must be unique too.** The compiler enforces unique globals but
  explicitly cannot see inside a prebuilt bundle; the final fold is
  `Object.assign(window.PhoenixKitHooks, <bundle globals…>)`, which is
  last-write-wins on hook names. So export `PhotoTimeline`, never something
  like `Grid`.

This is packaging work that has to exist before Stage 1 can run inside Fotki
at all — not an afterthought at publish time.

### 5.8. Cross-cutting, decided now rather than later

- **Viewer.** `on_open` emits to the existing MediaViewer /
  MediaCanvasViewer. PhotoTimeline does not grow a lightbox of its own.
  Returning from the viewer needs a return-to id in the URL
  (`?at=<file_uuid>`, or the section id), or back-from-viewer is a scroll reset.
- **Permissions.** Specify them in `permission_metadata/0` before the first
  route ships. Minimum: an owner sees their own library; an admin may see any
  user's; nobody else sees anything.
- **i18n.** PhoenixKit is multilingual. Month headers and scrubber labels go
  through Gettext, and the hook receives **already-formatted** labels — never
  English month names baked into JS.
- **Empty and first-run states.** Zero photos; "today's upload is still
  processing"; backfill in progress. These are the first thing a real user
  sees and the plan was silent on them.

---

## 6. Staged plan

It makes sense to move by how the product feels, not by how pretty the layout is.

### Stage 0 — data (a PhoenixKit core PR, see §5.1.1)

The largest stage, not a line item: there is no capture date in the system at
all (§3.4).

In core:

- columns `taken_at`, `taken_on`, `taken_at_offset`, `taken_at_source` on
  `phoenix_kit_files` — real columns, not expressions over jsonb: sorting
  100k+ rows by a JSONB key will not hold up;
- date extraction in `ProcessFileJob` via ImageMagick `identify` and `ffprobe`
  (no new system dependency for v1);
- an Oban backfill job on the `file_processing` queue re-reading the originals
  of already-uploaded files. Originals retain EXIF today (`sanitize/3` is not
  on the general ingest path), but re-verify that before it ever lands there;
- the partial composite index from §5.3.

In this package:

- the index API (monthly buckets, live aggregation — no bucket table yet);
- the window API (by **day**, capped at 500 items);
- every grid reads variants only, never the original.

The resolution order is in §5.3. It must be deterministic and re-runnable:
the whole of Stage 1 rests on `taken_on` being stable.

### Stage 1 — already "like Photos"

- the package path-dep'd into Fotki, with its prebuilt JS bundle (§5.7);
- square grid, N columns, `{:user, uuid}` scope only;
- virtualization by section;
- month header;
- jump from a list of dates;
- prefetch of adjacent days — without it, jump-to-date shows a blank month.

At 10k photos this is enough to tell whether the contract is right. Square
heights are exact, so this does **not** depend on Stage 2.

### Stage 2 — an honest scrollbar

Only needed once heights stop being exact — i.e. with justified layout or
variable row heights. Skip it for square.

- tombstones;
- height refinement;
- `scrollTop` correction when a section is recomputed;
- resize handling and **anchor-item** position restore (§5.4), whenever it
  is that resize first matters.

### Stage 3 — justified

- port the small justified algorithm into the hook. Flickr's
  `justified-layout` is old CommonJS; porting it (or Google's FlexLayout with
  shrink/stretch) beats bundling it;
- `@immich/justified-layout-wasm` only after a *measured* layout cost on a fat
  month. WASM inside the PhoenixKit asset compiler is a real cost — Safari,
  prebuild, CSP.

### Stage 4 — scrubber

- year → month;
- date overlay while scrolling;
- position restore when returning from the viewer (needs the return-to id
  from §5.8).

### Stage 5 — density and speed

- slider / pinch for 2–8 columns;
- prefetch by scroll direction and speed.

("Fat months split into days" has moved forward into Stage 0 — it is part of
the window contract, not a late optimization.)

### Acceptance gates

These are tests, not aspirations:

- **Stage 1 does not ship** until a 10k square library jumps to a random month
  without dropping frames in both Chrome and Safari, with a bounded DOM node
  count.
- **Stage 3 does not ship** until a 100k justified library does the same.
  Safari is why Immich needed a WASM round two — square-first is the right
  order.
- A synthetic 10k/100k seed with a realistic aspect mix (mostly 4:3 and 3:2,
  some 9:16, a few panoramas) lives in the package's test support.
- The hook needs unit tests for prefix-sum jump and scrollTop correction, and
  a browser test for "open viewer, return, still on the same tile".

Rough capacity:

- 10k, square grid, a careful hook — almost always fine;
- 100k+, justified — sections + height estimation + preview pyramid are mandatory;
- a million — the same ideas, but do not ship even the full list of ids to the
  client, only buckets.

---

## 7. The recommendation in one sentence

Take off-the-shelf code for the layout math and the preview pipeline.
Write our own for the **section index + LiveView contract + scrubbable grid**.

That exact piece exists neither in Hex nor in npm as a native Phoenix component.
For PhoenixKit it is a natural module sitting beside Storage and MediaBrowser,
not yet another JS gallery in `assets/vendor`.

Shape: the external module `phoenix_kit_media_timeline` (§5.1), path-dep'd
into Fotki from commit one. Put capture date on Storage's `phoenix_kit_files`
table in PhoenixKit core; put the section index and the scrubbable grid in the
package; and publish no scope and no bucket table that has not been used
against a 10k library.

The first stone is not the grid. It is `taken_on`.

---

## 8. Sources

- Antin Harasymiv — *Building the Google Photos Web UI*, Google Design, 2018.
- Analyses of the same model: scrubbable grid, sections / tombstones / DOM recycling.
- Shailesh Pandit — *How to Implement Google Photos Grid in JavaScript*.
- Immich: TimelineManager, justified-layout-wasm, pinch-zoom timeline.
- Flickr `justified-layout`.
- Phoenix LiveView streams + `phx-viewport-*` (good for a feed, not for a library).
- MDN: `content-visibility`, `contain-intrinsic-size`.
- Review of this plan: `dev_docs/reviews/2026-09-20-phoenix-kit-media-timeline.md`.
- PhoenixKit 2.32.1, sources: `lib/modules/storage/schemas/file.ex`,
  `schemas/file_instance.ex`, `schemas/dimension.ex`,
  `workers/process_file_job.ex`, `services/image_processor.ex`,
  `migrations/postgres/v135.ex`, `lib/phoenix_kit/module.ex`,
  `module_discovery.ex`, `module_registry.ex`, `known_packages.ex`,
  `lib/phoenix_kit_web/components/media_browser.ex`, `media_gallery.ex`,
  `components/core/event_timeline_item.ex`, `services/url_signer.ex`,
  `services/variant_generator.ex`, `lib/phoenix_kit/oban_queues.ex`,
  `lib/phoenix_kit/migrations/repair.ex`.
