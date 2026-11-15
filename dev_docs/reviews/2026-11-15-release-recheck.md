# Release recheck since Hex 0.3.0

Review of all 35 commits in `v0.3.0..560b084`, with fixes and regression coverage for
eight additional issues before the planned 0.4.0 release.

## Scope

The [Hex API](https://hex.pm/api/packages/phoenix_kit_photos) reported 0.3.0 as the
latest published release on 2026-11-15. Its git tag is `v0.3.0`. A fetch of origin
confirmed that `main` and `origin/main` both ended at `560b084` when this review began.
The working tree was clean. The existing 0.4.0 version is retained; no publishing or
tagging was performed.

This is a follow-up to [the earlier review](2026-11-15-since-0.3.0.md), including the
size-cap and cancel fixes made after that review. The range covers:

- Background upload staging, storing, retry/refusal handling, preview tiles, clipboard
  pasting, and the unconfirmed-email gate.
- Core 3.6 stacks: covers, page visibility, selection expansion, copying/moving,
  stack editing and viewer navigation.
- Link fetching: confirmation, ownership, cookies, tool arguments and process lifecycle,
  size limits, cancellation, retry and cleanup.
- Titles/dates/places/comments in the info panel, sharing audiences, place lookups,
  video startup and expired-link recovery.
- Chapters/sub-chapters/translations, calendar day sheets and view addresses, month links.
- The dependency/version changes, earlier review fixes, documentation and packaged bundle.

## Findings and fixes

| Severity | Finding | Fix and regression |
|---|---|---|
| HIGH | `Details.stack/2` used every untrashed page from `Stacks.files/1`, without checking read permissions. A Media stack can contain several people's uploads. `Details.load/4` returned hidden page UUIDs, and the rendered panel showed hidden page counts and the hidden cover's date. | Use the timeline's visible file query and read checks for the displayed pages, cover, position and manual-date flag. Editing still requires permission on the whole stack. `details_test`: mixed-owner Media stack, followed by only one readable page remaining. |
| HIGH | `InfoPanel.update/2` replaced `:auth`/`:scope` but retained already-loaded details. Even an update naming the same photo skipped reauthorization. | Reload and reset editing when either context changes, including when the UUID is unchanged. `info_panel_test`: replace the reader with someone without access, with and without `file_uuid` in the update. |
| MEDIUM | A reverse-geocoder result was checked only against the photo UUID. Changing that photo's place while its old lookup ran could label the new place with its old street. | Carry the lookup coordinates/language/detail in the result and apply it only while that exact lookup is still current. `info_panel_test`: reject an old result and accept a current one. |
| MEDIUM | Swiping A → B → A within the info panel's debounce left B's timer running: the early return for the already-shown A happened before clearing it. | Clear pending work before the early return. `info_panel.test.js`: advance a mocked clock after the quick return, then verify a later legitimate change still works. |
| MEDIUM | The capturing stack-key handler intercepted ArrowUp/Down and PageUp/Down inside the info panel and text fields, before the viewer's own keyboard guards. | Respect typing, panel focus and `defaultPrevented`. `timeline.test.js`: fields/panel/handled events stay untouched; a focused tile still skips the stack. |
| HIGH | Fetch size checks depended on output reaching `FetchJob`. A quiet chunked gallery download could grow without another line; the job could also be blocked storing a previous file. | The separate runner checks disk sizes once a second and terminates the process group with `:too_big`. Its stall deadline tracks actual output, so periodic checks cannot keep a stalled tool alive. `fetches_test`: a fake tool writes an oversized partial file and sleeps without printing progress. It now ends `failed/too_big` within the test deadline. Existing stall/cancel/owner-death tests still run. |
| MEDIUM | `StagingSweepJob` ran only once after activity. Its first run, an hour later, retained files younger than the 24-hour cutoff and never returned to remove them on an idle host. Fetch starts also scheduled cleanup exclusively on `photo_uploads`, which a fetch-only host need not run. | Schedule the next hourly sweep after each successful run, on its current queue. Fetch starts schedule on `photo_fetches`; uniqueness keeps at most one waiting per queue. `background_upload_test`: next run exists before any new scheduling call, repeated scheduling stays unique, and a fetch-queue sweep stays there. `fetches_test` checks the initial queue. |
| MEDIUM | `LiveUpdates` retains subscriptions for previously watched users, while `FetchList` accepted every incoming fetch and `LinkFetcher` checked only the library. Updating the page's reader could display another person's later fetch updates. | Both components check the fetch's owner against their current auth before accepting it. `fetches/components_test`: reject another user's event and still accept the current user's event in both components. |

The new regressions for visibility, cached-reader access, the debounce, stack keys,
silent oversized downloads, recurring cleanup and foreign fetch events were observed
failing before their respective fixes. The async lookup test also verifies the positive
path, so ignoring every result does not satisfy it.

## Documentation and packaging

- Corrected the README's old claim that tests never migrate: the helper runs migrations
  before entering per-case sandboxes. It now calls for a dedicated test database and
  ffmpeg for the video tests.
- Documented V1–V3 migrations, background queues/staging, link-fetch setup and the current
  info panel. Added the previously missing stacks, chapters, calendar, info-panel and
  clipboard features to the unreleased changelog and consolidated its duplicate Added
  sections.
- Rebuilt the minified shipped bundle with `mix assets.deploy`, keeping the existing
  packaging convention. No dependency versions or release versions were changed.

## Validation

| Check | Result |
|---|---|
| `mix precommit` | Passed: forced compilation with warnings as errors, unused-dependency check, Hex audit, formatting, strict Credo, Dialyzer, and ExUnit |
| ExUnit | **352 tests, 0 failures, 5 excluded**; both previously failing video tests ran with ffmpeg available |
| `cd assets && npm test` | **223 tests, 0 failures** |
| Synthetic Chromium browser regression | Passed with 10,000 photos: max 40 tile nodes, max 3 cached windows, max month jump 17 ms; large-day tail visible and stale response ignored |
| `mix assets.deploy` | Passed; production minified bundle rebuilt |
| `mix hex.build --output /tmp/photos-review-package.tar` | Passed; packaged release metadata, README, changelog, migrations and bundle checked against the working tree |
| `mix format --check-formatted`, `git diff --check` | Passed |

The initial run had 346 tests and the same two missing-ffmpeg failures noted by the
previous review; its 221 JavaScript tests passed. ffmpeg and Playwright were installed
for this review outside the repository. Chromium's missing OS libraries were downloaded
and unpacked under `/tmp`, then loaded through `LD_LIBRARY_PATH`; no system packages
were installed. Project JavaScript dependencies were restored with `npm ci` using the
existing lockfile. Dialyzer retains only the three existing, scoped ignored warnings.

## Limits

- The five `:real_tools` tests remain excluded by the suite's default. No live external
  sites or production egress proxy were exercised; fetch integration uses local fake
  tools and a real local storage bucket.
- The browser run is the repository's synthetic Chromium regression, not host acceptance
  with representative media in Chrome and Safari. The README keeps that distinction.
- Disk limits are sampled every second, so temporary downloads can overshoot between
  samples. The before-store check still refuses to store a file over the configured cap.
- Site-wide chapter notifications from the prior review remain unchanged. Consumers
  filter by library, and this pass did not introduce a subscription protocol change.
