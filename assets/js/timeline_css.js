// The looks of the timeline's styles. Their shapes are in layouts.js; the tile itself holds only
// its place, and `.pkt-paper` inside it carries the look, so a change of style can animate one
// without the other. The sheet ships with the hook: the package has no stylesheet of its own,
// and a host's Tailwind cannot see class names that are only ever set from here.

const CSS = `
.pkt-tile{position:absolute;padding:0;margin:0;border:0;background:none;cursor:pointer;pointer-events:auto;color:inherit;-webkit-tap-highlight-color:transparent;contain:layout style}
.pkt-tile:focus-visible{outline:2px solid var(--color-primary,#3b82f6);outline-offset:2px;z-index:4}
.pkt-paper{position:absolute;inset:0;display:block;overflow:hidden;background-color:var(--color-base-200,#e5e7eb);transition:inset .42s cubic-bezier(.2,.8,.2,1),border-radius .42s,box-shadow .42s,transform .42s cubic-bezier(.2,.8,.2,1),background-color .42s,padding .42s}
.pkt-paper img{position:absolute;left:var(--pkt-side,0px);top:var(--pkt-top,0px);width:calc(100% - 2*var(--pkt-side,0px));height:calc(100% - var(--pkt-top,0px) - var(--pkt-foot,0px));object-fit:cover;display:block;transition:left .42s,top .42s,width .42s,height .42s,border-radius .42s}
.pkt-badge{position:absolute;right:6px;bottom:6px;display:none;align-items:center;gap:3px;padding:1px 6px 1px 5px;border-radius:999px;background:#000a;color:#fff;font-size:11px;line-height:16px;font-variant-numeric:tabular-nums;pointer-events:none}
.pkt-tile[data-kind="video"] .pkt-badge{display:inline-flex}
.pkt-badge::before{content:"";border-left:7px solid currentColor;border-top:4px solid transparent;border-bottom:4px solid transparent}
.pkt-meta,.pkt-caption{position:absolute;display:block;opacity:0;pointer-events:none;transition:opacity .3s}

[data-active-style="rows"] .pkt-paper{border-radius:3px}
[data-active-style="columns"] .pkt-paper{border-radius:10px}
[data-active-style="mosaic"] .pkt-paper{border-radius:12px}
[data-active-style="whole"] .pkt-paper{border-radius:2px;box-shadow:0 1px 3px #0003}
[data-active-style="feed"] .pkt-paper{border-radius:16px;box-shadow:0 10px 30px -14px #0007}
[data-active-style="honeycomb"] .pkt-paper{border-radius:50%}
[data-active-style="honeycomb"] .pkt-badge{right:50%;transform:translateX(50%)}

[data-active-style="prints"] .pkt-paper{--pkt-side:6%;--pkt-top:5%;--pkt-foot:17%;background-color:#fbfaf5;border-radius:2px;box-shadow:0 1px 2px #0003,0 8px 18px -8px #0006;transform:rotate(var(--pkt-tilt,0deg))}
[data-active-style="prints"] .pkt-caption{opacity:1;left:6%;right:6%;bottom:0;height:17%;display:flex;align-items:center;justify-content:center;color:#57534e;font:italic 500 clamp(9px,1.2vw,13px)/1 ui-serif,Georgia,serif;white-space:nowrap;overflow:hidden}
[data-active-style="prints"] .pkt-badge{bottom:20%;right:9%}
[data-active-style="prints"] .pkt-paper,[data-active-style="prints"] .pkt-paper img{outline:1px solid transparent;will-change:transform}
@media (hover:hover){[data-active-style="prints"] .pkt-tile:hover{z-index:3}[data-active-style="prints"] .pkt-tile:hover .pkt-paper{transform:rotate(0deg) scale(1.05);box-shadow:0 2px 4px #0003,0 16px 28px -10px #0007}}

[data-active-style="film"] .pkt-paper{--pkt-side:3%;--pkt-top:13%;--pkt-foot:13%;background-color:#111113;border-radius:0}
[data-active-style="film"] .pkt-paper::before,[data-active-style="film"] .pkt-paper::after{content:"";position:absolute;left:0;right:0;height:6%;background:repeating-linear-gradient(90deg,transparent 0 6px,#e7e5e4d9 6px 13px,transparent 13px 19px);border-radius:1px}
[data-active-style="film"] .pkt-paper::before{top:3.5%}
[data-active-style="film"] .pkt-paper::after{bottom:3.5%}
[data-active-style="film"] .pkt-paper img{border-radius:3px}
[data-active-style="film"] .pkt-caption{opacity:1;right:6%;bottom:13.5%;color:#fbbf24;font:600 10px/1.2 ui-monospace,Menlo,monospace;text-shadow:0 0 3px #000}
[data-active-style="film"] .pkt-badge{left:6%;right:auto;bottom:15%}

[data-active-style="details"] .pkt-tile{border-radius:12px}
@media (hover:hover){[data-active-style="details"] .pkt-tile:hover{background:color-mix(in oklab,var(--color-base-content,#000) 6%,transparent)}}
[data-active-style="details"] .pkt-paper{inset:6px auto 6px 6px;width:60px;border-radius:9px}
[data-active-style="details"] .pkt-badge{left:9px;right:auto;bottom:9px;padding:0 4px;font-size:9px}
[data-active-style="details"] .pkt-meta{opacity:1;left:78px;right:10px;top:50%;transform:translateY(-50%);text-align:left;line-height:1.3;overflow:hidden;white-space:nowrap}
.pkt-name{display:block;overflow:hidden;text-overflow:ellipsis;font-size:14px;font-weight:600}
.pkt-sub{display:block;overflow:hidden;text-overflow:ellipsis;font-size:12px;opacity:.62;font-variant-numeric:tabular-nums}

.pkt-check{position:absolute;left:6px;top:6px;width:22px;height:22px;border-radius:50%;border:2px solid #fffd;background:#0003;box-shadow:0 0 0 1px #0002;opacity:0;transform:scale(.8);transition:opacity .14s,transform .14s,background-color .14s;display:none}
[data-selectable="true"] .pkt-check{display:block}
.pkt-check::after{content:"";position:absolute;left:5.5px;top:2px;width:6px;height:10px;border:solid #fff;border-width:0 2px 2px 0;transform:rotate(42deg);opacity:0}
@media (hover:hover){.pkt-tile:hover .pkt-check{opacity:1;transform:scale(1)}}
[data-selecting="true"] .pkt-check{opacity:1;transform:scale(1)}
.pkt-tile[data-selected] .pkt-check{background:var(--color-primary,#2563eb);border-color:var(--color-primary,#2563eb);opacity:1;transform:scale(1)}
.pkt-tile[data-selected] .pkt-check::after{opacity:1}
.pkt-tile[data-selected] .pkt-paper{transform:scale(.9);border-radius:10px;box-shadow:0 0 0 2px var(--color-primary,#2563eb)}
[data-active-style="prints"] .pkt-tile[data-selected] .pkt-paper{transform:rotate(var(--pkt-tilt,0deg)) scale(.93)}
[data-active-style="honeycomb"] .pkt-tile[data-selected] .pkt-paper{border-radius:50%}
[data-active-style="details"] .pkt-tile[data-selected]{background:color-mix(in oklab,var(--color-primary,#2563eb) 12%,transparent)}
[data-active-style="details"] .pkt-tile[data-selected] .pkt-paper{transform:none;box-shadow:none;border-radius:9px}
[data-active-style="details"] .pkt-check{left:auto;right:12px;top:50%;margin-top:-11px;border-color:color-mix(in oklab,var(--color-base-content,#000) 45%,transparent);background:transparent}
[data-active-style="honeycomb"] .pkt-check{left:14%;top:14%}
[data-dragging="true"]{user-select:none;-webkit-user-select:none;cursor:crosshair}
[data-selectable="true"] .pkt-tile{-webkit-touch-callout:none;-webkit-user-select:none;user-select:none}
.pkt-marquee{position:absolute;z-index:6;border:1px solid var(--color-primary,#2563eb);background:color-mix(in oklab,var(--color-primary,#2563eb) 16%,transparent);border-radius:3px;pointer-events:none}

.pkt-header{display:flex;align-items:center;gap:8px}
.pkt-section-check{pointer-events:auto;position:relative;width:20px;height:20px;padding:0;border-radius:50%;border:2px solid color-mix(in oklab,var(--color-base-content,#000) 40%,transparent);background:none;cursor:pointer;opacity:0;transition:opacity .14s}
.pkt-section-check::after{content:"";position:absolute;left:4.5px;top:1.5px;width:6px;height:10px;border:solid color-mix(in oklab,var(--color-base-content,#000) 55%,transparent);border-width:0 2px 2px 0;transform:rotate(42deg)}
@media (hover:hover){.pkt-header:hover .pkt-section-check,.pkt-section-check:focus-visible{opacity:1}}
[data-selecting="true"] .pkt-section-check{opacity:1}
@media (prefers-reduced-motion:reduce){.pkt-paper,.pkt-paper img,.pkt-meta,.pkt-caption,.pkt-check{transition:none}}
`

let installed = false

/** Put the sheet on the page, once. A constructed sheet needs no inline `<style>` for a strict CSP. */
export function installTimelineCss() {
  if (installed || typeof document === "undefined") return
  installed = true
  try {
    const sheet = new CSSStyleSheet()
    sheet.replaceSync(CSS)
    document.adoptedStyleSheets = [...document.adoptedStyleSheets, sheet]
  } catch (_error) {
    const style = document.createElement("style")
    style.textContent = CSS
    document.head.appendChild(style)
  }
}
