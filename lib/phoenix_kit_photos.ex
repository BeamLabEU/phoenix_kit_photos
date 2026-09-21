defmodule PhoenixKitPhotos do
  @moduledoc """
  A photo and video library for PhoenixKit, in the spirit of Apple Photos and
  Google Photos.

  The timeline is the first view and the spine of the product: albums, people,
  map and memories are scopes and views over the same date-ordered, virtualized
  engine. See `dev_docs/plans/2026-09-21-phoenix-kit-photos.md` for why this is
  a separate package rather than a MediaBrowser view mode in core.

  This is the PhoenixKit module entry point: `PhoenixKit.ModuleDiscovery` finds
  it by scanning beam attributes of deps that depend on `:phoenix_kit`, so a
  host application needs no configuration beyond the dependency itself.

  ## What this module is, and is not

  Three media widgets exist and must not be conflated:

    * `PhoenixKitWeb.Components.MediaBrowser` — file work: folders, ingest, search.
    * `PhoenixKitWeb.Components.MediaGallery` — picking and ordering a set of
      images for a form.
    * `PhoenixKitPhotos.Components.PhotoTimeline` — a person's library
      ordered by capture date, virtualized and scrubbable.

  ## Status

  Stage 0 is not complete. The timeline needs capture-date columns
  (`taken_at`, `taken_on`, `taken_at_offset`, `taken_at_source`) on Storage's
  `phoenix_kit_files` table, which live in PhoenixKit core rather than here —
  see `dev_docs/plans/2026-09-20-phoenix-kit-media-timeline.md` §5.1.1.
  `PhoenixKitPhotos.Timeline` reports that plainly rather than guessing
  a date from `inserted_at`.
  """

  use PhoenixKit.Module

  @version Mix.Project.config()[:version]

  @setting_key "photos_enabled"

  @impl PhoenixKit.Module
  def module_key, do: "photos"

  @impl PhoenixKit.Module
  def module_name, do: "Photos"

  @impl PhoenixKit.Module
  def version, do: @version

  @impl PhoenixKit.Module
  def enabled?, do: PhoenixKit.Settings.get_boolean_setting(@setting_key, false)

  @impl PhoenixKit.Module
  def enable_system do
    PhoenixKit.Settings.update_boolean_setting_with_module(@setting_key, true, module_key())
  end

  @impl PhoenixKit.Module
  def disable_system do
    PhoenixKit.Settings.update_boolean_setting_with_module(@setting_key, false, module_key())
  end

  # The timeline reads Storage's files, variants and dimensions. Without the
  # Storage module there is nothing to show.
  @impl PhoenixKit.Module
  def required_modules, do: ["storage"]

  # Path-dep installs resolve through this absolute fallback; Hex installs
  # resolve the OTP app name. Emitting both keeps one entry working in each
  # case without the host application toggling anything.
  @source_root Path.expand(Path.join(__DIR__, ".."))

  @doc """
  Tailwind source roots, so classes used only in this package's HEEx survive
  the host's CSS build.

  Without this the `:phoenix_kit_css_sources` compiler warns that a
  phoenix_kit-dependent dep contributes zero `@source` lines, and any
  responsive or variant utility used only here is silently missing from the
  host bundle.
  """
  @impl PhoenixKit.Module
  def css_sources, do: [:phoenix_kit_photos, @source_root]

  @doc """
  The prebuilt hook bundle, built by `mix assets.build` into this app's `priv/`.

  `js_sources/0` does not compile anything — it declares a bundle that already
  exists, which is why building it is a Stage 1 deliverable and not a packaging
  afterthought.
  """
  @impl PhoenixKit.Module
  def js_sources do
    [
      %{
        app: :phoenix_kit_photos,
        file: "static/assets/phoenix_kit_photos.js",
        global: "PhoenixKitPhotosHooks"
      }
    ]
  end

  @doc """
  Claim `photos` so no other module's routes take it.
  """
  @impl PhoenixKit.Module
  def reserved_route_prefixes, do: ["photos"]

  @doc """
  The package's default page, at `/photos`.

  A `user_dashboard_tabs/0` entry carrying a `live_view` becomes a real route
  in PhoenixKit's authenticated surface, which is emitted **twice** — once at
  the root and once locale-scoped — so this one callback yields both `/photos`
  and `/:locale/photos`, permission-gated.

  That is also why there is no `route_module/0` here: it would emit a third,
  duplicate `/photos` and the host router would warn that the clause can never
  match. The one trade is that this page depends on the user dashboard being
  enabled in the host.

  The `path` is absolute on purpose — a relative one resolves under
  `/dashboard/`.

  A host wanting its own branded page declares `/photos` before
  `phoenix_kit_routes()`; first match wins, so the host shadows the root shape
  without this package knowing about it.
  """
  @impl PhoenixKit.Module
  def user_dashboard_tabs do
    [
      %PhoenixKit.Dashboard.Tab{
        id: :photos,
        label: "Photos",
        icon: "hero-photo",
        path: "/photos",
        priority: 200,
        level: :user,
        permission: "photos",
        match: :prefix,
        live_view: {PhoenixKitPhotos.Web.TimelineLive, :index}
      }
    ]
  end

  @doc """
  Permissions, specified before the first route ships rather than after.

  An owner sees their own library; `photos.view_any` additionally
  allows viewing another user's. Nobody else sees anything: a signed thumbnail
  URL is not authorization (`URLSigner` tokens are 4 hex characters and never
  expire), so the window API is what enforces scope.
  """
  @impl PhoenixKit.Module
  def permission_metadata do
    %{
      key: "photos",
      label: "Photos",
      icon: "hero-photo",
      description: "Photo and video library, ordered by capture date",
      sub_permissions: [
        %{
          key: "view_any",
          label: "View any user's timeline",
          description: "Browse another user's media library, not only your own"
        }
      ]
    }
  end
end
