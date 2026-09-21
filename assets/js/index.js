// Bundle entry point. esbuild is configured with
// --global-name=PhoenixKitMediaTimelineHooks, so these named exports become
// window.PhoenixKitMediaTimelineHooks.<Name>, which the
// :phoenix_kit_js_sources compiler folds into window.PhoenixKitHooks.
export { PhotoTimeline } from "./photo_timeline"
