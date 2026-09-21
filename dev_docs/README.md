# dev_docs

Working documentation for development: reviews, reports, and plans.

This is scratch-to-durable material — the record of *why* something was done
and what was found. It is not user documentation and not API docs (those
belong in `@moduledoc`/`@doc` and ExDoc output, which lands in the gitignored
`/doc/`).

## Structure

| Directory | What goes here |
|---|---|
| `reviews/` | Code review findings, security reviews, audits of existing code |
| `reports/` | Outcomes: upgrades performed, incidents, benchmarks, investigations |
| `plans/` | Proposals and implementation plans written *before* the work |

## Naming convention

Every file is prefixed with the date it was created, in ISO form, followed by
a short kebab-case slug:

```
YYYY-MM-DD-short-slug.md
```

Examples:

```
dev_docs/reports/2026-09-19-asset-toolchain-upgrade.md
dev_docs/reviews/2026-09-19-upload-pipeline.md
dev_docs/plans/2026-09-19-thumbnail-generation.md
```

ISO dates sort chronologically in a plain directory listing, so `ls` gives
you the timeline for free.

Notes:

- The date is when the document was **created**, and it does not change when
  the file is later edited. To supersede a document, write a new one and link
  back to the old.
- One topic per file. Prefer a new dated file over appending to an old one —
  the history is the point.
- Start each file with an `# H1` title and a one-line summary, so the content
  is identifiable without relying on the filename alone.
