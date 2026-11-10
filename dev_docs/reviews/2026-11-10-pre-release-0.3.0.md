# Pre-release review for 0.3.0 (2026-11-10)

Scope: the commits since `3f2092f` (2026-11-05). That range covers the timeline styles,
multi-select and bulk actions, the API tools, the download plug, the Calendar style, and
the fixes that followed them. Two independent reviewers read it, one for the server and
one for the browser. Every finding was checked against the code before anything was
changed.

0.3.0 had been tagged but never published, so this ships as 0.3.0 and the tag moves to
the reviewed commit.

## Gate before the review

- **Elixir tests.** 3 of 182 failed in `test/photo_timeline_test.exs`. The fault was in
  the tests, not the code. Since `192ffea`, the page sends an index of its own (`hello:
  false`) before the hook's hello. The tests never consumed it, so a later
  `assert_push_event(..., %{total: 0})` matched that stale push instead of the one it
  meant. Setup now consumes the page's index.
- **Credo `--strict`.** 7 issues: `Bulk.check_action/5` was too complex,
  `PhotoTimeline.start_run/2` was nested too deep, `Download.call/2` had a one-branch
  `cond`, plus alias and number-format items. All are fixed.

## Server: fixed

| Finding | Fix |
|---|---|
| `timeline:range` with a `from`/`to` past int64 raised `DBConnection.EncodeError` and crashed the LiveView | `integer/1` is bounded at 2^31-1, as `parse_window/1` already was |
| `photos.find_files` (API) called `Libraries.can?/3` per row, about 1,000 queries per call for a member | Memoized per `{library_uuid, user_uuid}`, as `Bulk.rights/2` does |
| `aspects_sent` was kept across a library switch (same component id). Months whose ratios hashed equal were never sent to the hook, which had dropped its aspects, so the whole-photo styles stayed on averages | Reset when the index reloads for a new scope or auth |
| The host's removal guard was called inline, with no timeout and case-sensitive uuids. It also accepted places for files nobody asked about | Asked in a monitored process under `:file_removal_guard_timeout`, uuids compared in lower case, and any off-contract answer fails closed. This is core's media-browser behaviour |
| `timeline:aspects`, `timeline:range` and `timeline:need_window` without their keys raised `FunctionClauseError` | No-op fallback clauses |
| The download plug raised on `ids[a]=x` (`to_string/1` of a map) and returned a 500 | Only the form's comma-separated string is read; anything else asks for nothing (404) |
| `timeline:bulk_undo` could start a restore while another run was in flight | Refused while `running` |
| The tag inputs re-planned the whole bulk action on every keystroke | `phx-debounce="300"` |
| daisyUI 4 `*-bordered` classes were back in the new markup | Removed (see the umbrella AGENTS.md sweep) |

## Browser: fixed

| Finding | Fix |
|---|---|
| A box drag held at the bottom edge of the library scrolled on into blank space. The box grew by the edge speed even when the page could not move, and since it lives inside the scroller it made the page taller | The box follows only the distance the page really moved, and the loop ends when that is 0 |
| `drawBox` rebuilt every month's layout once per selected tile (about 50 ms per pointermove with 2,000 hits) | Geometry is computed once per draw |
| The root click listener was unbound through `closest()` after LiveView had already removed the hook's element. It leaked, and a second hook doubled bar clicks | The root is kept at bind time |
| Box and touch-paint selection ignored the selection limit (the bar could say 7,000 while the server cut to 5,000) | Both go through `addWithinLimit`, which shows the capped note |
| Escape closing the style menu also cleared the selection. Delete/Escape/Ctrl+A acted under the bulk dialog, and Ctrl+A was taken page-wide | Keys are ignored while the menu or dialog is open, and Ctrl/Cmd+A only applies when focus is in the timeline or on `body` |
| Calendar weeks started on Monday everywhere in browsers without week info (Firefox) | CLDR fallback table by `Intl.Locale#maximize().region` |
| Every tile popped in on the first load: the hello's index counted as a refresh | Pop-in only when something was already on screen |
| A pen's long-press began a paint that only `touchend` could end | The hold-to-paint path is for touch only |
| Picking a style hid the focused button | Focus returns to the menu toggle |

The bundle (`priv/static/assets/phoenix_kit_photos.js`) is rebuilt with `mix
assets.deploy`, the minified build. Before these changes the committed bundle was
byte-identical to that build. Building needs `cd assets && npm ci` first: photoswipe
comes from `assets/node_modules`.

## Left open

- **A refresh does not drop deleted files from the selection.** The server only ever
  sends `selection: %{clear: true}`, so the `remove` branch of `applySelection` is unused.
  Files trashed on another device stay counted, and the dialog lists them as refused.
- **Accessibility.** Tiles carry no `aria-pressed` for selection, and the label
  "Open photo" does not change while selecting.
- **`timeline:range` is computed against the current database.** A shift-range taken
  during someone else's upload can pick neighbouring files. Trash is reversible, and the
  dialog shows the plan first.
- **A move whose trash step fails after the copy leaves a duplicate**, and a retry is
  refused as `:already_there` (`bulk.ex`, move path).
- **The index is read three times per page view**: dead render, connected mount, and the
  hello. The connected-mount read is discarded by design.
- **ZIP entry names**: `.`, `..` and Windows-reserved characters are not sanitised
  beyond `Path.basename`.
- **No headless-browser run in this environment** (Chromium lacks `libnspr4`). Covered by
  `node --test` (164) and the Elixir suite (185).
