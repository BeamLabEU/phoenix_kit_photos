import Config

# The bundle js_sources/0 declares. Two rules, both enforceable only here:
#
#   * --global-name must be unique across every PhoenixKit module. The
#     :phoenix_kit_js_sources compiler folds window.<Global> into
#     window.PhoenixKitHooks and fails loudly on a duplicate global.
#   * The hook names *inside* the bundle must be unique too — that fold is
#     last-write-wins and the compiler cannot see inside a prebuilt bundle.
#     Hence `PhotoTimeline`, never something generic like `Grid`.
#
# PhoenixKit concatenates each bundle inside `;(function(){ ... })();`, so
# esbuild's `var <Name> = ...` is function-scoped and never reaches window on
# its own — the generated fold would assign an empty object and silently
# register no hooks at all. Hence the explicit footer assignment below.
config :esbuild,
  version: "0.28.2",
  module: [
    args:
      ~w(
      js/index.js
      --bundle
      --format=iife
      --global-name=PhoenixKitPhotosHooks
      --target=es2020
      --outfile=../priv/static/assets/phoenix_kit_photos.js
    ) ++
        [
          # Assign onto the real `window` explicitly. `--global-name=window.X`
          # and `--global-name=globalThis.X` both make esbuild emit
          # `var window = window || {}`, which inside PhoenixKit's wrapper
          # shadows the real global with a local and loses every hook.
          "--footer:js=window.PhoenixKitPhotosHooks=PhoenixKitPhotosHooks;"
        ],
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => Path.expand("../deps", __DIR__)}
  ]
