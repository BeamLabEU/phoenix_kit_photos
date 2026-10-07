// Bundle entry point. esbuild is configured with
// --global-name=PhoenixKitPhotosHooks, so these named exports become
// window.PhoenixKitPhotosHooks.<Name>, which the
// :phoenix_kit_js_sources compiler folds into window.PhoenixKitHooks.
import { installViewerWarm } from "./viewer_warm"

export { PhotoTimeline } from "./photo_timeline"

// Not a hook: a listener for core's media viewer (`pk:viewer-neighbours`).
// It must exist on every page the viewer can open on, not on a mounted
// element, so it installs when the bundle loads.
if (typeof window !== "undefined") installViewerWarm(window)
