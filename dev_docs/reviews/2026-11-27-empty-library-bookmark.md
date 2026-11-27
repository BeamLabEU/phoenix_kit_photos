# Empty library bookmark

PR #1 fixes the yellow bookmark appearing in an empty timeline.

The hook appends the marker hidden. Once the index arrives, the existing row-position calculation controls its visibility. When the last photo disappears, the empty-index path renders the marker again and hides it. The rebuilt bundle matches the PR byte for byte.

**Minor test finding.** The regression test manually scrolled after each index update. Those calls could mask a regression where the marker stays stale until the next user interaction. The revised test checks visibility immediately after each index update, including adding the first photo and removing it.

All 230 JavaScript tests passed, along with the bookmark, bookmark reopen, selection and styles Chromium regressions. Compilation, the Hex audit, formatting, Credo and Dialyzer passed. With ffmpeg available, ExUnit reported 360 tests, one failure and five exclusions. The bulk fingerprint test lost the internal PubSub registry and passed in isolation with the same seed (737939). Earlier runs also saw intermittent failures in the PubSub setup and the fetch runner.
