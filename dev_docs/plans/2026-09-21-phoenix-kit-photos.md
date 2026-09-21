# PhoenixKit Photos: renamed from media_timeline, rescoped as a Photos-class library

The package is `phoenix_kit_photos`, not `phoenix_kit_media_timeline`. The
timeline is the first view and the spine of the product, not the whole product.

Created: 2026-09-21
Supersedes: the name and scope in
[`2026-09-20-phoenix-kit-media-timeline.md`](2026-09-20-phoenix-kit-media-timeline.md)
§5.1. Everything else in that plan still stands — the architecture, the Stage 0
capture-date work, the query filter, the window sizing and the stage gates. Read
its names through the table below.

---

## 1. Why the rename

The question that forced it: **if this is only a better media grid, why is it a
separate package at all?**

That is a fair challenge, and the 2026-09-20 plan never answered it. Its §5.1
compared a generic Hex library with a PhoenixKit module. It never compared a
separate package with **core itself**. With Stage 0 (capture date) already going
upstream into Storage, a scrubbable grid alone is a date-bucket query, a JS hook
and a LiveComponent — a view mode for MediaBrowser. A package just to hold that
is overhead.

So the two honest options were:

| If the product is… | Then it belongs… |
|---|---|
| only the scrubbable grid | in PhoenixKit core, as a MediaBrowser view mode |
| a Photos-class library — albums, people, map, memories | in its own package |

We are building the second. Under that scope `media_timeline` is simply the wrong
name: it names one view of the product.

## 2. The timeline is the spine, not a feature

Almost everything a Photos-class library offers is a *scope* or a *view* over the
same date-ordered, virtualized engine the timeline already defines:

| Feature | Architecturally |
|---|---|
| Timeline | the date-ordered, virtualized grid |
| Albums, Collections | a **scope** — `{:album, id}` |
| People, Pets | a **scope** over detected subjects |
| Map | a different **view** over the same assets |
| Memories | queries over `taken_on` ("this day, N years ago") |

This is why nothing in the 2026-09-20 architecture changes. It already held
`{:album, id}` and `{:share, token}` out of the v1 component contract; that was
a decision about *order*, not a ceiling on scope. The index API, the day-window
API and the hook's two JSON shapes are the shared substrate every one of these
features reads through.

## 3. Names

| | Was | Now |
|---|---|---|
| Hex package / OTP app | `phoenix_kit_media_timeline` | `phoenix_kit_photos` |
| Namespace | `PhoenixKitMediaTimeline` | `PhoenixKitPhotos` |
| `module_key/0` | `media_timeline` | `photos` |
| Admin label (`humanize_key`) | Media Timeline | Photos |
| Setting | `media_timeline_enabled` | `photos_enabled` |
| Permissions | `media_timeline`, `media_timeline.view_any` | `photos`, `photos.view_any` |
| JS global | `PhoenixKitMediaTimelineHooks` | `PhoenixKitPhotosHooks` |
| Bundle | `phoenix_kit_media_timeline.js` | `phoenix_kit_photos.js` |
| CSS block | `phoenix-kit-media-timeline` | `phoenix-kit-photo-timeline` |
| GitHub | `BeamLabEU/phoenix_kit_media_timeline` | `BeamLabEU/phoenix_kit_photos` |
| Route | `/photos` | `/photos` (unchanged) |

**Unchanged on purpose:** the component `PhotoTimeline`, the hook `PhotoTimeline`,
`PhoenixKitPhotos.Timeline` and `PhoenixKitPhotos.Web.TimelineLive`. Under the
new scope these names became *more* accurate: the timeline is one view inside
Photos. The CSS block follows the component (`phoenix-kit-photo-timeline`), not
the package, for the same reason.

Why `photos`:

- it is the word users already know; Apple Photos and Google Photos both handle
  video, so it does not read as images-only;
- the route (`/photos`) and the tab label ("Photos") already used it, so the key,
  the label and the URL now agree;
- free on Hex; in PhoenixKit core it appears only incidentally
  (`preview_card.ex`, `avatar_crop.ex`), never as a module key or route.

Rejected: `gallery` (collides with core's `MediaGallery`), `library` (collides
conceptually with MediaBrowser), `albums` and `memories` (each names one feature).

## 4. What the broader name commits us to

The name promises features with real costs. None of them are in v1, but each has
a prerequisite that should be known before it is started.

### Map needs GPS — a second upstream change

`ProcessFileJob` does not extract GPS any more than it extracts capture date, and
`ImageProcessor.sanitize/3` strips it on purpose. Map therefore needs the same
kind of core PR as Stage 0.

GPS is also the most sensitive field in a photo library. **Per-user visibility of
location has to exist before any sharing does**, or an album share leaks where
someone lives. Treat that as a gate on Map, not a follow-up.

### People needs an ML pipeline and an opt-in

Face detection, embeddings, clustering, a model runtime (Bumblebee/Nx or an
external service) and very likely pgvector.

In the EU, grouping faces is likely biometric processing under GDPR Art. 9, and
Google shipped face grouping off by default in some regions for that reason.
**Opt-in from day one**, per user, with a way to delete the derived data — not
something retrofitted after the pipeline exists.

**Pets** carries the ML cost without the biometric question.

### Albums need tables

New tables owned by this package. Albums are also the natural first non-timeline
feature, since `{:album, id}` is just the next scope for the component already
being built.

## 5. v1 is unchanged

Timeline first, with the gates from the 2026-09-20 plan §6: Stage 0 capture date
upstream, then a 10k square grid in Chrome and Safari, then justified at 100k.
The rename changes what the package is *called* and where it is *going*, not
what ships first.

## 6. Persisted state from the old name

Being discovered once under the old key was enough for PhoenixKit to write rows
to Fotki's dev database:

- `phoenix_kit_role_permissions`: `media_timeline` and `media_timeline.view_any`,
  auto-granted to a role;
- `phoenix_kit_settings`: `auto_granted_perm:media_timeline` and
  `auto_granted_perm:media_timeline.view_any`, the markers that stop the grant
  from being repeated.

Those four rows were deleted during the rename, and PhoenixKit re-granted under
`photos` on the next boot. **Any other install that ran the old name needs the
same cleanup**, though at this stage Fotki's dev database is the only one.
