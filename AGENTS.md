# PhoenixKit Photos contributor guidance

## Design for every installation

Never hardcode a choice that can vary by installation, environment, library, or user. Read the choice from the settings of the site or person who owns it. Discover available options from the registry and each integration’s declared capabilities, respecting ownership and permissions. Keep vendor-specific behavior inside its adapter.

For example, a bucket’s **Configure CDN** action opens the CDN-capable integrations available to its owner, even when only one provider qualifies. Registering a second compatible provider should make it available without editing the bucket screen.

## Content-Security-Policy

The package has to work under a host policy that allows inline code by nonce only (`script-src 'self' 'nonce-…'; style-src 'self' 'nonce-…'`). The core requirement in `mix.exs` stays as it is, so everything here is feature-detected.

- **A `<style>` the bundle creates is stamped before it is inserted**: `adoptStyle(document.createElement("style"))`, from `assets/js/csp.js`. It calls core's `window.PhoenixKitInternals.adoptStyle` when the core in use has it and does nothing otherwise. Never write a `<style>` or `<script>` as a string for `innerHTML`, and create no `<script>`. Rebuild and commit the bundle (`mix assets.deploy`) after any change in `assets/js/`.
- **No inline event handlers** (`onclick=` …) in HEEx or in markup the JavaScript builds: no nonce covers an attribute. Use a `phx-` binding or a hook of the bundle.
- **No inline `<script>` or `<style>` in `lib/`** today. One that is added carries the nonce, read through a small helper that calls `PhoenixKitWeb.CSP.nonce/1` with `apply/3` behind `Code.ensure_loaded?/1` and `function_exported?/3` (core 3.7 has no such module; `nonce={nil}` renders no attribute).
- The lints: `test/csp_inline_tags_test.exs` (markup, sources and the built bundle) and `assets/test/csp.test.js` (the stamping itself).
- Not covered by a nonce: inline `style="…"` attributes (the host allows them with `style-src-attr 'unsafe-inline'`), and Leaflet and PhotoSwipe inside the bundle, which set styles through the DOM and create no `<style>` or `<script>`.
