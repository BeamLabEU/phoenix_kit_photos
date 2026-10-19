# PhoenixKit Photos

A photo and video library for [PhoenixKit](https://hex.pm/packages/phoenix_kit),
in the spirit of Apple Photos and Google Photos.

Not a gallery. The target is a person opening **their entire library spanning
decades** — grabbing the scrubber, jumping to March 2016, and not killing the
tab at 200,000 files.

## Scope

The timeline comes first, and it is the spine rather than one feature among
many: nearly everything else is a scope or a view over the same date-ordered,
virtualized engine.

| Feature | What it is | Status |
|---|---|---|
| Timeline | the date-ordered, scrubbable grid | in progress |
| Albums, Collections | a scope — `{:album, id}` | planned |
| People, Pets | a scope over detected subjects | planned |
| Map | a view over the same assets | planned |
| Memories | queries over capture date | planned |

If this were only the grid, it would belong in PhoenixKit core as a
MediaBrowser view mode. It is a separate package because of everything after
the first row.

## Status: Stage 1, square grid

The timeline reads one storage library (`{:library, uuid}`), grouped by the
local capture date `taken_on`. PhoenixKit 2.41.0 already stores that date and
the library partition; this package does not add either.

The 10k gate from the plan — a square library of 10k photos, a jump to a
random month, in Chrome and Safari, with a bounded DOM count — is measured in
Fotki, the host. Automated Chromium checks now cover a synthetic 10k grid
and a signed-in Fotki page, including month jumps, large-day tails, viewer
return, mobile sizing, and library switching. Images in those tests are
synthetic placeholders. The full Chrome/Safari gate with representative
media has not passed, so Stage 1 is not claimed as shipped.

See `dev_docs/plans/2026-09-20-phoenix-kit-media-timeline.md` for the design
(written under the package's original name), `dev_docs/reviews/` for the review
it incorporates, and `dev_docs/plans/2026-09-21-phoenix-kit-photos.md` for the
rename and the broader scope.

## Installation

```elixir
def deps do
  [
    {:phoenix_kit, "~> 2.41"},
    {:phoenix_kit_photos, "~> 0.1"}
  ]
end
```

No configuration. `PhoenixKit.ModuleDiscovery` finds any dependency that
depends on `:phoenix_kit` and uses `PhoenixKit.Module`, by scanning beam
attributes.

During development, path-dep it instead:

```elixir
{:phoenix_kit_photos, path: "../phoenix_kit_photos"}
```

## Three widgets, never to be conflated

| Widget | Job |
|---|---|
| `PhoenixKitWeb.Components.MediaBrowser` | File work: folders, ingest, search |
| `PhoenixKitWeb.Components.MediaGallery` | Picking and ordering images for a form |
| `PhoenixKitPhotos.Components.PhotoTimeline` | A library ordered by capture date |

## Usage

Subscribe in the parent LiveView (use your component's ID):

```elixir
on_mount {PhoenixKitPhotos.LiveUpdates, "library"}
```

```elixir
<.live_component
  module={PhoenixKitPhotos.Components.PhotoTimeline}
  id="library"
  scope={{:library, library_uuid}}
  auth={scope}
  layout={:square}
  columns={5}
  on_open="open_asset"
/>
```

`library_uuid` is one storage library. `PhoenixKitPhotos.Timeline.libraries/1`
lists Media plus the user's owned and shared libraries, and `default_library_uuid/1` picks
the one to open. Media is enough to measure the grid and does not require
user libraries to be enabled.

The supplied page and Fotki open PhoenixKit's existing canvas viewer in a
read-only dialog. `?at=<uuid>` identifies the open file; closing patches the
URL and keeps the timeline mounted at the same position. Custom `on_open`
handlers must reauthorize the UUID with `Timeline.viewer_file/3`.

The v1 contract is deliberately narrow: one library, `:square` layout only,
no `on_select`. Albums, shares, justified layout and the scrubber are later
stages.

## Architecture

LiveView owns permissions, window transport and PubSub. The JS hook owns
geometry, DOM recycling and the scrubber. The seam between them is two JSON
shapes:

- **index** — monthly buckets with counts, the whole library in a few hundred
  entries. This is what lets the scrollbar be a map of time.
- **window** — a day or a slice of a large day, capped at 500 items. The first
  slice is `YYYY-MM-DD`; later slices are `YYYY-MM-DD:500`, `:1000`, etc.
  Counts and geometry include all slices, so no photo is silently truncated.

Window requests target their component, and replies are namespaced by
component ID and index revision. Refreshes invalidate the cache; stale
responses are ignored. The hook retains only visible and adjacent windows.
Tiles fit the container width and resizing preserves the same row.

`assets/js/geometry.js` is pure math with no DOM and no framework, and is unit
tested (`cd assets && npm test`).

## The viewer of a library

Each library chooses how its photos open (`PhoenixKitPhotos.Viewer`):

| Viewer | What it is |
|---|---|
| **Swipe viewer** (`"photoswipe"`, the default) | Swipe between photos and videos, pinch and double-tap zoom, drag down to close, the fly from and to the tile; [PhotoSwipe](https://photoswipe.com) 5 under it |
| **Classic viewer** (`"classic"`) | PhoenixKit's own media viewer (`MediaCanvasViewer`): one file at a time, with its sidebar, comments and annotations |

The choice is the library's own setting, this package's (`Libraries.put_module_setting(library, "photos",
"viewer", name)`: core keeps it in the library's `settings` under the package's namespace and knows nothing
of it), so it follows the library to every browser. A library that has not chosen
follows `config :phoenix_kit_photos, default_viewer: "classic" | "photoswipe"` (`"photoswipe"` when
unset). `Components.ViewerPicker` is the select for it: it shows nothing to someone who may not
choose (a user library's owner and managers; for Media, the site's admins), and tells its page
`{:viewer_changed, library_uuid}`. The page passes `Viewer.pager(Viewer.for_library(library))` as
`PhotoTimeline`'s `pager`. In the swipe viewer, an **Info** button opens the classic viewer on the
file on screen, so details, comments and annotations are one tap away.

## The swipe viewer's engines

`PhotoTimeline`'s `pager` is `false` (the host's own viewer, on `on_open`), `true` (the default
engine) or an engine's name. The engines are interchangeable behind one contract
(`assets/js/viewer/engine.js`), so a library can be swapped without touching the timeline:

| Engine | What it is |
|---|---|
| `photoswipe` (default) | PhotoSwipe: gestures, zoom, the fly to and from the tile |
| `snap` | The browser's own scroll-snap: native swipe feel; no zoom, a fade instead of the fly, no drag to close. Registered, but not one a library can choose: a baseline to compare with |

The timeline owns the data (the index, which slides are loaded, what to ask for next, the grid and
scrolling it to the file on screen); an engine owns gestures, transitions and its DOM. Videos are built
by the shared `VideoController` (poster first, nothing fetched until played, the file chosen for the
screen, HDR kept where it can be shown, the next file tried when one fails), so they behave alike in
every engine. A name the page does not know falls back to the default engine. To add one: write a
class with the contract's methods, register it in `viewer/engines.js`, add its name to
`PhoenixKitPhotos.Viewer` to offer it, and rebuild the bundle.

## Core media viewer: warming originals

Core's media viewer is deliberately plain: it warms only each neighbour's `small` and
`large`, once the current picture has settled. Whether a multi-MB **original** is worth
fetching ahead of an arrow press is high-end viewing, so it is decided here
(`assets/js/viewer_warm.js`). Core announces `pk:viewer-neighbours` and this bundle
answers: only where `large` (1920 px) will not do, judged on the width the picture is
actually *displayed* at (its aspect fitted in the viewer box, times the pixel ratio — a
portrait photo in a wide window is narrow), one original (the neighbour in the direction
last stepped, the next before any step), low priority, never on data-saver or a 2G/3G
line. Choosing a better file by real display class (5K and up) and window size
belongs in the same file.

## Development

```bash
mix deps.get
mix assets.build    # rebuilds priv/static/assets/phoenix_kit_photos.js
MIX_ENV=test mix test   # PG* / DB_* must point at a migrated, sandboxable DB
cd assets && npm test
```

`js_sources/0` declares a **prebuilt** bundle — it does not compile one. Run
`mix assets.build` after touching anything in `assets/js/`, and commit the
output: it ships in the Hex package.

The SQL suite does not create or migrate a database. Each case uses SQL
Sandbox; never add fixtures that commit. `test/support/synthetic_library.ex`
provides 10k/100k fixtures for a caller-owned sandbox transaction.

The standalone DOM regression needs Playwright and its Chromium browser:

```bash
cd assets
node test/browser.mjs
```

Set `PLAYWRIGHT_MODULE` to an installed Playwright module when it is not a
local dependency, and `PLAYWRIGHT_BROWSERS_PATH` when using a shared browser
installation. Fotki's `scripts/photos_browser_host.exs` and `test/browser/photos.mjs`
contain the authenticated host check.
Month msgids are extracted into `priv/gettext/default.pot`; translations can
be added with the standard Gettext tools.

## License

MIT
