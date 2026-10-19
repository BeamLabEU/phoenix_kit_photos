import { registerEngine } from "./engine.js"

// The engines the viewer can use. Each is loaded the first time it is chosen
// (esbuild keeps them in the one bundle, but does not run one until it is used).
// Add an engine here, give it the contract in engine.js, and a host can name it.
registerEngine("photoswipe", () => import("./photoswipe.js").then((m) => m.PhotoSwipeEngine))
registerEngine("snap", () => import("./snap.js").then((m) => m.SnapEngine))
