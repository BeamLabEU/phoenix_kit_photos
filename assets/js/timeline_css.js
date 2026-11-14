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
.pkt-stack{position:absolute;right:6px;top:6px;display:none;align-items:center;gap:4px;padding:1px 6px 1px 5px;border-radius:999px;background:#000a;color:#fff;font-size:11px;font-weight:600;line-height:16px;font-variant-numeric:tabular-nums;pointer-events:none}
.pkt-tile[data-stack] .pkt-stack{display:inline-flex}
.pkt-stack::before{content:"";width:8px;height:8px;margin:2px 2px 0 0;border:1.5px solid currentColor;border-radius:2px;box-shadow:2px -2px 0 -0.5px #000a,2px -2px 0 1px currentColor}
.pkt-tile[data-stack] .pkt-paper{box-shadow:3px -3px 0 -1px var(--color-base-100,#fff),3px -3px 0 0 color-mix(in oklab,var(--color-base-content,#000) 28%,transparent)}

[data-active-style="rows"] .pkt-paper{border-radius:3px}
[data-active-style="columns"] .pkt-paper{border-radius:10px}
[data-active-style="mosaic"] .pkt-paper{border-radius:12px}
[data-active-style="whole"] .pkt-paper{border-radius:2px;box-shadow:0 1px 3px #0003}
[data-active-style="feed"] .pkt-paper{border-radius:16px;box-shadow:0 10px 30px -14px #0007}
[data-active-style="honeycomb"] .pkt-paper{border-radius:50%}
[data-active-style="honeycomb"] .pkt-badge{right:50%;transform:translateX(50%)}
[data-active-style="honeycomb"] .pkt-stack{right:50%;top:8%;transform:translateX(50%)}
[data-active-style="honeycomb"] .pkt-tile[data-stack] .pkt-paper,[data-active-style="details"] .pkt-tile[data-stack] .pkt-paper,[data-active-style="calendar"] .pkt-tile[data-stack] .pkt-paper{box-shadow:none}
[data-active-style="prints"] .pkt-stack{top:7%;right:9%}
[data-active-style="film"] .pkt-stack{top:15%;right:6%}
[data-active-style="details"] .pkt-stack{left:9px;right:auto;top:9px;padding:0 4px;font-size:9px}
[data-active-style="details"] .pkt-stack::before{display:none}
[data-active-style="calendar"] .pkt-stack{right:3px;top:3px;padding:0 4px;font-size:9px;line-height:13px}
[data-active-style="calendar"] .pkt-stack::before{display:none}

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

[data-active-style="calendar"] .pkt-paper{border-radius:4px}
[data-active-style="calendar"] .pkt-badge{right:3px;bottom:3px;padding:3px 3px 3px 4px;gap:0;font-size:0;line-height:0}
[data-active-style="calendar"] .pkt-check{width:18px;height:18px;left:4px;top:4px}
[data-active-style="calendar"] .pkt-check::after{left:4px;top:1px;width:5px;height:9px}
.pkt-cal{position:absolute;left:0;right:0;pointer-events:none;animation:pkt-cal-in .3s ease-out}
.pkt-cal-back{z-index:-1}
.pkt-cal-front{z-index:2}
.pkt-cal>div{position:absolute}
.pkt-cal-wd{display:flex;align-items:center;justify-content:center;font-size:11px;font-weight:600;letter-spacing:.04em;text-transform:uppercase;opacity:.55}
.pkt-cal-day{border-radius:6px;background:color-mix(in oklab,var(--color-base-content,#000) 4%,transparent)}
.pkt-cal-front .pkt-cal-day{background:none}
.pkt-cal-num{position:absolute;top:3px;right:5px;min-width:18px;padding:0 4px;border-radius:999px;text-align:center;font-size:12px;font-weight:600;line-height:18px;font-variant-numeric:tabular-nums;opacity:.5}
.pkt-cal-future{opacity:.45}
.pkt-cal-weekend .pkt-cal-num,.pkt-cal-wd.pkt-cal-weekend{opacity:.38}
.pkt-cal-full .pkt-cal-num{opacity:1;color:#fff;text-shadow:0 1px 3px #000b,0 0 1px #000a}
.pkt-cal-today .pkt-cal-num{opacity:1;color:var(--color-primary-content,#fff);background:var(--color-primary,#2563eb);text-shadow:none}
.pkt-cal-more{display:flex;align-items:center;justify-content:center;border-radius:4px;background:#0009;color:#fff;font-weight:600;font-variant-numeric:tabular-nums}
.pkt-cal-count{position:absolute;left:3px;bottom:3px;padding:0 5px;border-radius:999px;background:#000a;color:#fff;font-size:10px;font-weight:600;line-height:15px;font-variant-numeric:tabular-nums}
@keyframes pkt-cal-in{from{opacity:0}}

.pkt-header{display:flex;align-items:center;gap:8px}
.pkt-section-check{pointer-events:auto;position:relative;width:20px;height:20px;padding:0;border-radius:50%;border:2px solid color-mix(in oklab,var(--color-base-content,#000) 40%,transparent);background:none;cursor:pointer;opacity:0;transition:opacity .14s}
.pkt-section-check::after{content:"";position:absolute;left:4.5px;top:1.5px;width:6px;height:10px;border:solid color-mix(in oklab,var(--color-base-content,#000) 55%,transparent);border-width:0 2px 2px 0;transform:rotate(42deg)}
@media (hover:hover){.pkt-header:hover .pkt-section-check,.pkt-section-check:focus-visible{opacity:1}}
[data-selecting="true"] .pkt-section-check{opacity:1}
.pkt-chapter--sky{--pkt-ch:#0ea5e9}
.pkt-chapter--rose{--pkt-ch:#f43f5e}
.pkt-chapter--amber{--pkt-ch:#f59e0b}
.pkt-chapter--emerald{--pkt-ch:#10b981}
.pkt-chapter--violet{--pkt-ch:#8b5cf6}
.pkt-chapter--slate{--pkt-ch:#64748b}
.pkt-banner-host{display:block;padding:14px 0 10px;pointer-events:none}
.pkt-banner-host.pkt-banner-fill{padding-left:8px;padding-right:8px}
.pkt-banner--sub{padding:10px 0 8px 18px}
.pkt-banner-fill.pkt-banner--sub{padding-left:26px}
.pkt-banner--sub::before{content:"";position:absolute;left:7px;top:0;bottom:8px;width:2px;border-radius:2px;background:color-mix(in oklab,var(--pkt-ch) 45%,transparent)}
.pkt-banner-fill.pkt-banner--sub::before{left:15px}
.pkt-banner{position:relative;display:flex;align-items:center;gap:14px;height:100%;padding:10px 44px 10px 10px;border-radius:18px;overflow:hidden;pointer-events:auto;
  background:linear-gradient(105deg,color-mix(in oklab,var(--pkt-ch) 22%,var(--color-base-100,#fff)) 0%,color-mix(in oklab,var(--pkt-ch) 7%,var(--color-base-100,#fff)) 55%,var(--color-base-100,#fff) 100%);
  border:1px solid color-mix(in oklab,var(--pkt-ch) 30%,transparent);box-shadow:0 1px 2px #0000000d,0 10px 24px -18px color-mix(in oklab,var(--pkt-ch) 80%,#000)}
.pkt-banner::after{content:"";position:absolute;left:0;top:0;bottom:0;width:4px;background:var(--pkt-ch)}
.pkt-banner[data-chapter-edit]{cursor:pointer}
@media (hover:hover){.pkt-banner[data-chapter-edit]:hover .pkt-banner-edit{opacity:1}}
.pkt-banner-cover{position:relative;flex:none;width:84px;height:84px;margin-left:4px;border-radius:14px;overflow:hidden;display:grid;place-items:center;background:color-mix(in oklab,var(--pkt-ch) 18%,var(--color-base-100,#fff));box-shadow:0 0 0 1px color-mix(in oklab,var(--pkt-ch) 25%,transparent)}
.pkt-banner-cover img{position:absolute;inset:0;width:100%;height:100%;object-fit:cover}
.pkt-banner-emoji{font-size:40px;line-height:1}
.pkt-banner-badge{position:absolute;right:4px;bottom:4px;display:grid;place-items:center;min-width:26px;height:26px;padding:0 3px;border-radius:999px;background:var(--color-base-100,#fff);box-shadow:0 1px 3px #0004;font-size:15px;line-height:1}
.pkt-banner-text{min-width:0;flex:1;display:flex;flex-direction:column;gap:1px}
.pkt-banner-kicker{font-size:11px;font-weight:700;letter-spacing:.08em;text-transform:uppercase;color:color-mix(in oklab,var(--pkt-ch) 75%,var(--color-base-content,#000));white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.pkt-banner-title{font-size:22px;font-weight:750;line-height:1.2;letter-spacing:-.01em;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.pkt-banner-meta{font-size:13px;line-height:1.35;opacity:.72;font-variant-numeric:tabular-nums;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.pkt-banner-desc{font-size:13px;line-height:1.35;opacity:.85;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.pkt-banner-edit{position:absolute;right:10px;top:50%;margin-top:-14px;display:grid;place-items:center;width:28px;height:28px;border-radius:999px;color:var(--color-base-content,#000);background:color-mix(in oklab,var(--color-base-100,#fff) 70%,transparent);opacity:.55;transition:opacity .14s}
.pkt-banner .pkt-section-check{position:absolute;right:46px;top:50%;margin-top:-10px}
.pkt-banner--sub .pkt-banner{gap:12px;padding:8px 44px 8px 8px;border-radius:14px}
.pkt-banner--sub .pkt-banner-cover{width:54px;height:54px;border-radius:11px}
.pkt-banner--sub .pkt-banner-emoji{font-size:26px}
.pkt-banner--sub .pkt-banner-badge{min-width:20px;height:20px;font-size:11px;right:2px;bottom:2px}
.pkt-banner--sub .pkt-banner-title{font-size:17px}
.pkt-banner--sub .pkt-banner-kicker{text-transform:none;letter-spacing:0;font-weight:600;font-size:12px}
.pkt-banner--sub .pkt-banner-meta{font-size:12px}
@media (max-width:480px){.pkt-banner-cover{width:72px;height:72px}.pkt-banner-title{font-size:19px}.pkt-banner{gap:12px}}
.pkt-chip{pointer-events:auto;display:inline-flex;align-items:center;max-width:14rem;padding:1px 9px;border-radius:999px;border:0;cursor:pointer;font-size:12px;font-weight:600;line-height:20px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;color:color-mix(in oklab,var(--pkt-ch) 70%,var(--color-base-content,#000));background:color-mix(in oklab,var(--pkt-ch) 16%,transparent)}
.pkt-chip--after{font-weight:500;background:none;box-shadow:inset 0 0 0 1px color-mix(in oklab,var(--pkt-ch) 35%,transparent)}
.pkt-chapter-swatch{position:relative;display:block;width:30px;height:30px;border-radius:999px;cursor:pointer;background:var(--pkt-ch);box-shadow:0 0 0 2px var(--color-base-100,#fff),0 0 0 3px color-mix(in oklab,var(--pkt-ch) 40%,transparent)}
.pkt-chapter-swatch:has(input:checked){box-shadow:0 0 0 2px var(--color-base-100,#fff),0 0 0 4px var(--pkt-ch)}
.pkt-chapter-swatch:has(input:focus-visible){outline:2px solid var(--color-base-content,#000);outline-offset:4px}
.pkt-pending{display:none}
.pkt-tile[data-pending]{cursor:progress}
.pkt-tile[data-pending] .pkt-paper{background-image:linear-gradient(100deg,transparent 30%,color-mix(in oklab,var(--color-base-100,#fff) 70%,transparent) 50%,transparent 70%);background-size:200% 100%;animation:pkt-shimmer 1.6s linear infinite}
.pkt-tile[data-pending] .pkt-paper img:not([src]){display:none}
.pkt-tile[data-pending] .pkt-paper img{filter:blur(1.5px) saturate(.85);opacity:.8}
.pkt-tile[data-pending] .pkt-pending{display:block;position:absolute;left:50%;top:50%;width:24px;height:24px;margin:-12px 0 0 -12px;border-radius:50%;border:3px solid #fff;border-top-color:transparent;filter:drop-shadow(0 0 2px #0009);animation:pkt-spin .8s linear infinite;z-index:1}
.pkt-tile[data-pending] .pkt-check{display:none}
@keyframes pkt-shimmer{from{background-position:200% 0}to{background-position:-200% 0}}
@keyframes pkt-spin{to{transform:rotate(360deg)}}
@media (prefers-reduced-motion:reduce){.pkt-paper,.pkt-paper img,.pkt-meta,.pkt-caption,.pkt-check{transition:none}.pkt-cal{animation:none}.pkt-tile[data-pending] .pkt-paper{animation:none}.pkt-tile[data-pending] .pkt-pending{animation-duration:2.4s}}
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
