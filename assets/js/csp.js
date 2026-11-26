// A `<style>` this bundle adds to the page is checked against the host's Content-Security-Policy
// like one written in the page: under `style-src 'nonce-…'` the browser drops it unless it
// carries the page's nonce. Core's bundle knows that nonce and stamps an element with it
// (`window.PhoenixKitInternals.adoptStyle`); a core that has no such function (3.7 and older)
// has no nonce to give either, and the element goes in as it always did.
//
// Call it on every `<style>` this bundle creates, right after `createElement` and before the
// element joins the document: a nonce set later is not looked at.

export function adoptStyle(el) {
  const internals = typeof window === "undefined" ? null : window.PhoenixKitInternals
  if (el && internals && typeof internals.adoptStyle === "function") internals.adoptStyle(el)
  return el
}
