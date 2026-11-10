# Changelog

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
