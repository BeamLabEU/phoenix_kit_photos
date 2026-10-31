// Hook/DOM regression for window focus without a visibility change; Safari acceptance is separate.
import { fileURLToPath } from "node:url"
const { chromium } = await import(process.env.PLAYWRIGHT_MODULE || "playwright")
import assert from "node:assert/strict"
(async()=>{
 const browser=await chromium.launch({args:['--no-sandbox']});
 try {
 const page=await browser.newPage();
 const errors=[];page.on('pageerror',e=>errors.push(e.message));
 await page.route('http://bookmark.test/**',route=>route.fulfill({contentType:'text/html',body:`<div class="phoenix-kit-photo-timeline" style="--photo-timeline-inset-top:56px"><div id="grid" data-timeline-id="test" data-target="1" data-cell="170" style="position:fixed;inset:0;overflow-y:auto"><div class="phoenix-kit-photo-timeline__spacer"></div><div class="phoenix-kit-photo-timeline__layer" style="position:absolute;top:0;left:0;right:0"></div></div></div>`}));
 const mount=async()=>{
  await page.addScriptTag({path: fileURLToPath(new URL("../../priv/static/assets/phoenix_kit_photos.js", import.meta.url))});
  await page.evaluate(()=>{
   window.h=Object.assign({},window.PhoenixKitPhotosHooks.PhotoTimeline,{el:document.querySelector('#grid'),pushEventTo(){},handleEvent(){}});
   h.mounted();h.setIndex({library:'a',revision:1,sections:[{id:'2020-01',count:1000,days_list:[]}]});
  });await page.waitForTimeout(200);
 };
 await page.goto('http://bookmark.test');await mount();
 await page.evaluate(()=>{h.beginPositionInput({type:"wheel"});h.el.scrollTop=2345;h.handleScroll();});
 await page.waitForTimeout(100);
 const saved=await page.evaluate(()=>sessionStorage.getItem(h.positionKey()));
 // Switching applications on desktop: visibility remains visible, only blur fires.
 await page.evaluate(()=>{
  window.dispatchEvent(new Event('blur'));
  h.el.scrollTop=h.el.scrollHeight;
 });await page.waitForTimeout(150);
 await page.evaluate(()=>{
  h.el.dispatchEvent(new PointerEvent('pointerdown',{clientX:400,bubbles:true}));
  window.dispatchEvent(new Event('focus'));
  h.reconnected();
 });await page.waitForTimeout(200);
 assert.equal(await page.evaluate(()=>document.visibilityState),'visible');
 assert.equal(await page.evaluate(()=>h.el.scrollTop),2345);
 assert.equal(await page.evaluate(()=>sessionStorage.getItem(h.positionKey())),saved);
 await page.reload();await mount();
 assert.equal(await page.evaluate(()=>h.el.scrollTop),2345);
 await page.evaluate(()=>{h.el.scrollTop=h.el.scrollHeight;});await page.waitForTimeout(150);
 assert.equal(await page.evaluate(()=>h.el.scrollTop),2345);
 await page.mouse.move(400,300);await page.mouse.wheel(0,300);await page.waitForTimeout(200);
 assert(await page.evaluate(()=>h.el.scrollTop)>2345);
 assert.notEqual(await page.evaluate(()=>sessionStorage.getItem(h.positionKey())),saved);
 assert.deepEqual(errors,[]);
 console.log('PASS: visible-window blur/focus, activation click, reconnect, reload, late browser scroll, and real wheel input');
 }finally{await browser.close();}
})();
