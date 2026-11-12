# Changelog

## Unreleased

### Fixed

- An account whose email is not confirmed is now told so instead of "You may not add
  to this library". The page let it upload, and `StoreUploadJob`, which reads the
  account again, refused every file without saying why (nor logging it). The uploader
  now opens with *Check your email to continue*, the address the link went to and a
  way to have it sent again, in place of *Choose files*; files chosen, dropped or
  pasted anyway are turned away before they are sent, each with "Your email is not
  confirmed yet"; `Uploads.store/4`, `precheck/4` and the job answer
  `{:error, :email_unconfirmed}` (`Uploads.blocked/1`), and the job logs a refusal.

- The uploader no longer loses a photo when storage is slow. It stored each finished
  file while the page waited; a store over ~10 s made LiveView's client time out a push,
  disconnect and reload the page, which deleted the temp files of every upload in
  flight. A finished file is now moved out of LiveView's hands at once
  (`PhoenixKitPhotos.UploadStaging`) and stored by `PhoenixKitPhotos.StoreUploadJob`,
  retried for about 20 minutes while storage is down. The panel shows *Saving…* until
  it is stored.

- A bulk copy or move that fails for a file now says why in the log (the file and the
  error); the person was told "failed" and the log said nothing.

### Added

- `PhoenixKitPhotos.StoreUploadJob` (Oban queue `photo_uploads`): add
  `photo_uploads: 4` to the host's Oban queues. Without it, or on a page without
  `PhoenixKitPhotos.LiveUpdates`, the uploader stores inline as before.
- `config :phoenix_kit_photos, :staging_dir` (default `phoenix_kit_photos_staging` in
  the system temp directory; keep it on the same filesystem as Plug's temp files) and
  `:store_in_background` (`true`/`false` to force the choice).
- `PhoenixKitPhotos.StagingSweepJob`, scheduled by itself, removes staged files a
  crash left behind.
- `Uploads.precheck/4`: the cheap checks `store/4` starts with.
- `oban` as a direct dependency (it already came with PhoenixKit).

## 0.3.0 - 2026-11-10

The first release on Hex. Requires Elixir `~> 1.18` and PhoenixKit `~> 3.5`.

### Added

- Timeline over one storage library, `{:library, uuid}`: virtualized and scrubbable,
  grouped by capture date, with pinch, ctrl+wheel and keyboard zoom, and new uploads
  shown in place.
- Eleven timeline styles with an animated change between them: Grid, Rows, Columns,
  Mosaic, Uncropped, Feed, Prints, Film, Honeycomb, Details and Calendar (each month as
  a wall calendar, with the week starting on the reader's region's first day).
- Multi-select by click, Shift-range, box drag, touch hold-and-slide, month, day,
  "this moment" and kind. Bulk actions: download (streamed ZIP), copy links, copy or
  move to another library, tag, trash with undo.
- API tools for the timeline (`PhoenixKitPhotos.Api`).
- A LiveView photo uploader: a floating + button, drag and drop of files and folders, a
  frontend concurrency control, SVG checked by its bytes, and camera RAW.
- A swipe viewer with interchangeable engines and a viewer setting per library. A
  photo's address opens the viewer.
- Library audiences and per-library viewer preferences, and bookmarks that survive
  reconnects, reloads and browser restarts.

### Fixed

- Before the release, a review fixed:
  - a LiveView crash on an out-of-range `timeline:range` position;
  - a crash in the download plug on malformed `ids`;
  - an N+1 in `photos.find_files`;
  - a removal guard that could hang the page or match uuids case-sensitively;
  - box selection scrolling on into blank space at the library's end;
  - box and touch selection ignoring the selection limit;
  - a leaked click listener;
  - keys acting under the style menu and the bulk dialog;
  - Monday-first calendars in Firefox everywhere;
  - every tile popping in on first load.

  See `dev_docs/reviews/2026-11-10-pre-release-0.3.0.md`.
