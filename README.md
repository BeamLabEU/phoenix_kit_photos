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

## Status: skeleton

The package registers with PhoenixKit and ships its hook bundle. It does not
render a library yet, because **Stage 0 is not done**: capture date does not
exist in PhoenixKit core.

`PhoenixKit.Modules.Storage` extracts only `width`, `height`, `duration` at
ingest — no EXIF `DateTimeOriginal`, no `taken_at` column. Until that lands,
`PhoenixKitPhotos.Timeline` returns `{:error, :capture_date_unavailable}`
rather than bucketing a library by upload date, which would look plausible and
be wrong.

See `dev_docs/plans/2026-09-20-phoenix-kit-media-timeline.md` for the design
(written under the package's original name), `dev_docs/reviews/` for the review
it incorporates, and `dev_docs/plans/2026-09-21-phoenix-kit-photos.md` for the
rename and the broader scope.

## Installation

```elixir
def deps do
  [{:phoenix_kit_photos, "~> 0.1"}]
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

```elixir
<.live_component
  module={PhoenixKitPhotos.Components.PhotoTimeline}
  id="library"
  scope={{:user, user.uuid}}
  layout={:square}
  columns={5}
  on_open="open_asset"
/>
```

The v1 contract is deliberately narrow: `{:user, uuid}` scope only, `:square`
layout only, no `on_select`. Albums, shares, justified layout and the scrubber
are later stages — publishing them now means withdrawing a published API later.

## Architecture

LiveView owns permissions, window transport and PubSub. The JS hook owns
geometry, DOM recycling and the scrubber. The seam between them is two JSON
shapes:

- **index** — monthly buckets with counts, the whole library in a few hundred
  entries. This is what lets the scrollbar be a map of time.
- **window** — one **day** of items, capped at 500. Days rather than months
  because a 20k-item holiday month is ~5MB over the socket.

`assets/js/geometry.js` is pure math with no DOM and no framework, and is unit
tested (`cd assets && npm test`).

## Development

```bash
mix deps.get
mix assets.build    # rebuilds priv/static/assets/phoenix_kit_photos.js
mix test
cd assets && npm test
```

`js_sources/0` declares a **prebuilt** bundle — it does not compile one. Run
`mix assets.build` after touching anything in `assets/js/`, and commit the
output: it ships in the Hex package.

## License

MIT
