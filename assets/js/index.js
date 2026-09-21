// Bundle entry point. esbuild is configured with
// --global-name=PhoenixKitPhotosHooks, so these named exports become
// window.PhoenixKitPhotosHooks.<Name>, which the
// :phoenix_kit_js_sources compiler folds into window.PhoenixKitHooks.
export { PhotoTimeline } from "./photo_timeline"
