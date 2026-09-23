# PhoenixKit Photos roadmap after Stage 0

Stage 0 (capture date) has landed in PhoenixKit core. This file covers what
core now provides, what it still lacks, and the order of work in this package
from Stage 1 onward.

Created: 2026-09-22

Builds on, and does not replace:

- [`2026-09-20-phoenix-kit-media-timeline.md`](2026-09-20-phoenix-kit-media-timeline.md):
  architecture, the query filter, the JSON contracts, stages 0–5 and their
  gates. Section numbers like "§5.3" refer to this plan.
- [`2026-09-21-phoenix-kit-photos.md`](2026-09-21-phoenix-kit-photos.md):
  the rename and the Photos-class scope.

> **Update 2026-09-22: libraries.** Core will partition files into
> **libraries** (system-wide and user-defined, such as Personal, Business or one
> per project), each with members and its own storage profile. The design is in
> core: `/www/phoenix_kit/dev_docs/plans/2026-09-22-storage-libraries.md`.
> For this package:
>
> - The timeline scope is `{:library, uuid}`, not `{:user, uuid}`, everywhere
>   below (§3 Step 1 and Step 3). A cross-library "everything I can see" view
>   is `library_uuid = ANY(...)`. Permissions become library membership, not
>   ownership.
> - **Step 1 waits on core V201** (Phase 1 of that plan). V201 replaces V200's
>   user-keyed capture-date index with `(library_uuid, taken_on, taken_at)`.
>   Do not write the real queries against `user_uuid` in the meantime.
> - **Personal libraries wait on core V202** (private serving: expiring file
>   URLs, no public redirects). Until then, build and measure against a system
>   library. Personal photos must not ship before V202.
> - Location-truth (V203), storage profiles (V204) and user-owned storage
>   (V205) do not block the timeline.
>
> (Release numbers revised 2026-09-23 after the Grok review of the core plan.)

---

## 0. This is a library

Fotki (`/www/app`) is the **first host**, not the product owner. Every other
PhoenixKit install should be able to add this package and get a working
library at `/photos`. So:

- nothing here names Fotki, reads Fotki config, or assumes Fotki's layout,
  routes or JS;
- anything a host needs to change goes through a documented option
  (component attrs, `config :phoenix_kit_photos`, a PhoenixKit setting), not
  an edit to the package;
- the package ships its own working page (`Web.TimelineLive`). A host may
  shadow it, as Fotki does with `FotkiWeb.PhotosLive`, but it does not have to;
- the synthetic seed lives in `test/support`, so any host (and CI) can use it.

Fotki's own plan (`/www/app/dev_docs/plans/2026-09-22-fotki-roadmap.md`)
covers app concerns and tracks which package milestones it is waiting for.

## 1. What core provides now

Checked against `/www/phoenix_kit` at `f5d5877a` (PhoenixKit 2.37.0, V200,
not yet on Hex):

- [x] `taken_at`, `taken_on`, `taken_at_offset`, `taken_at_source` on
      `phoenix_kit_files`.
- [x] `phoenix_kit_files_capture_date_index` on
      `(user_uuid, taken_on DESC, taken_at DESC)`. Its partial predicate
      matches the §5.3 filter, except for `width > 0 AND height > 0`. Keep
      that condition in the query; the index still serves it.
- [x] `Storage.CaptureDate`: EXIF, then video container tags, then filename,
      then `inserted_at`. A ranked guard (`replace?/2`, `admit/2`) never
      downgrades a date and never overwrites `"manual"`.
- [x] `ProcessFileJob` fills the dates on ingest. Copies and dedups inherit
      the donor's date.
- [x] `Workers.CaptureDateBackfillJob` and
      `mix phoenix_kit.storage.backfill_capture_dates`.
- [x] File lifecycle PubSub (`subscribe_to_file_events/0`): processed,
      trashed, restored, deleted, and the bulk folder variants.

**That is enough for Stages 1–5.** None of the timeline stages needs another
core release.

### Gaps in core, and what each one blocks

| Gap | Blocks | Needed by |
|---|---|---|
| No public API writes a `"manual"` date | Date correction in the viewer | Before real imports. Wrong camera clocks are common. |
| No event when a capture date changes; the backfill job does not broadcast | Live regrouping after a backfill or a manual edit | With the manual-date API. A reload is fine for a backfill. |
| No GPS extraction; `sanitize/3` strips it on purpose | Map | The map stage (a core PR like Stage 0). |
| No bulk or resumable import path beyond MediaBrowser upload | Loading a real multi-year library | Decide during Stage 1 (§3, Step 3). |

## 2. Current state of this package

- `Timeline.index/1` and `window/2` are stubs. They return
  `{:error, :capture_date_unavailable}` for every scope.
- `PhotoTimeline.load_index/1` matches only the error tuple. There will be a
  `MatchError` on the day `index/1` returns `{:ok, _}` without a matching
  clause.
- First `geometry.js` and `photo_timeline.js` exist. The bundle builds to
  `priv/static/assets/phoenix_kit_photos.js`.
- `mix.exs` asks for `{:phoenix_kit, "~> 2.32"}`, but the package now needs
  V200.

## 3. Order of work

### Step 1: Real queries

- `index/1`: monthly buckets through live `GROUP BY taken_on`, with no bucket
  table, over the full §5.3 filter.
- `window/2`: one day, capped at 500, subdivided if a day exceeds the cap.
- The `{:ok, _}` clause in `load_index/1`, in the same commit.
- Reserve `{:error, :capture_date_unavailable}` for a schema that really lacks
  the columns. A host on an older core should get that message, not a crash.
- Bump the requirement to `{:phoenix_kit, "~> 2.37"}`.

### Step 2: Seed and fixtures (`test/support`)

- A synthetic 10k/100k generator with a realistic aspect mix (mostly 4:3 and
  3:2, some 9:16, a few panoramas), spread over many years, with some fat
  days above 500 items.
- A few real fixture files that go through `ProcessFileJob`: EXIF with an
  offset, EXIF without one, a phone video, a filename-dated file, and a file
  with no date.
- A public entry point (for example
  `PhoenixKitPhotos.Seed.run(user_uuid, count)`) so a host can call it from
  its own dev seeds.

### Step 3: Stage 1, the square timeline

As specified in §5.3–§5.8:

- `permission_metadata/0`: an owner sees their own library, an admin may see
  any user's, and nobody else sees anything. Check scope in the window API;
  a signed URL does not authorize.
- Variants resolved by "smallest enabled aspect-preserving dimension", not by
  name.
- Square grid, section virtualization, month headers, jump from a list of
  dates, and prefetch of the neighbouring days.
- Realtime through file events, updating the bucket named by the row's
  `taken_on`, never "today".
- Gettext-formatted labels passed to the hook.
- Empty, processing and backfill-in-progress states.
- The component must work at any container width. Hosts choose the layout.

Decide during Stage 1 who owns **import**. Loading decades of photos is not
Fotki-specific; every host of this library needs it. Either MediaBrowser upload
is enough for v1, or bulk import (folder drop, resumable upload, a Takeout or
iCloud export, a server-side directory) is a package feature built on core
Storage. Consider the `file_processing` queue load (10k jobs per import) and
checksum dedup on re-import. That decision likely needs its own plan.

**Gate:** a 10k square library jumps to a random month without dropped frames
in Chrome and Safari, with a bounded DOM node count. Measure it in Fotki (the
first host) and record it in this repo's `dev_docs/reports/`.

### Step 4: Stages 2–5

An honest scrollbar, justified layout, the scrubber, then density and speed,
in the order of §6. The 100k justified gate must pass before Stage 3 ships.
Return-to-position from the viewer needs `?at=<file_uuid>` (§5.8).

### Step 5: Manual date correction

A core PR adds `Storage.set_capture_date/2` (source `"manual"`) and a broadcast
when a date changes. This package then adds the viewer action and regroups
live. Move this earlier if real imports show many bad dates.

### Step 6: Beyond the timeline

In the order of the 2026-09-21 plan §4:

1. **Albums.** Package tables through `migration_module/0`, and an
   `{:album, id}` scope. First decide whether MediaBrowser folders already
   serve (`{:folder, uuid}`).
2. **Sharing.** Share tokens and a new authorization path.
3. **Memories.** Queries over `taken_on`.
4. **Map.** The GPS core PR first, and per-user location visibility
   **before** sharing can expose a location.
5. **People / Pets.** An ML runtime and pgvector. People is opt-in per user,
   and a user can delete the derived data.

### Step 7: Publish

Publish to Hex once core 2.37.0 is on Hex and the v1 contract (the component
attrs, `index/1` and `window/2`, and the two JSON shapes) has been used against
a 10k library. Fill in `meta.links.GitHub` and keep the `hex_docs_icon_name`
marker (§5.1).
