// The map in the swipe viewer's info panel (`PhoenixKitPhotos.Components.InfoPanel`): where a
// photo was taken, as a pin, or as a circle when the library shows only the area. In the
// place editor (`data-editable="true"`) a click puts the pin there and the pin can be dragged;
// either sends `place_pin` with the spot to the panel, which names it and offers to save it.
//
// Leaflet draws it from the tiles the server names (`data-tiles`, `data-attribution`), so a site
// can move off OpenStreetMap's own tile server without touching this file. The pin is drawn in
// CSS, so the map needs no image files.

import L from "leaflet"
import leafletCss from "leaflet/dist/leaflet.css"
import { addStyle } from "./viewer/video.js"

const CSS = `
.pk-place-map .leaflet-container{background:transparent;font:inherit}
.pk-place-map .leaflet-control-attribution{font-size:10px;background:#0008;color:#fffc}
.pk-place-map .leaflet-control-attribution a{color:#fff}
.pk-place-pin{width:26px;height:26px}
.pk-place-pin span{position:absolute;left:3px;top:0;width:20px;height:20px;border-radius:50% 50% 50% 0;background:oklch(65% .22 25);border:2px solid #fff;transform:rotate(-45deg);box-shadow:0 3px 8px #0007}
.pk-place-pin span::after{content:"";position:absolute;left:5px;top:5px;width:6px;height:6px;border-radius:50%;background:#fff}
.pk-place-map--editable .leaflet-container{cursor:crosshair}
`

const number = (value) => {
  const n = parseFloat(value)
  return Number.isFinite(n) ? n : null
}

const triple = (value) => {
  const parts = String(value || "").split(",").map(number)
  return parts.length === 3 && parts.every((n) => n !== null) ? parts : null
}

const pinIcon = () =>
  L.divIcon({ className: "pk-place-pin", html: "<span></span>", iconSize: [26, 26], iconAnchor: [13, 26] })

export const PhotoPlaceMap = {
  mounted() {
    addStyle("pk-leaflet-css", leafletCss + CSS)
    this.draw()
    // The panel may still be opening (a sheet sliding up): measure again once it has settled.
    this.settle = setTimeout(() => this.map && this.map.invalidateSize(), 350)
    this.onResize = () => this.map && this.map.invalidateSize()
    window.addEventListener("resize", this.onResize)
  },

  updated() {
    this.place()
  },

  destroyed() {
    clearTimeout(this.settle)
    window.removeEventListener("resize", this.onResize)
    if (this.map) this.map.remove()
    this.map = null
  },

  draw() {
    const el = this.el
    const editable = el.dataset.editable === "true"
    el.classList.toggle("pk-place-map--editable", editable)

    this.map = L.map(el, {
      zoomControl: true,
      attributionControl: true,
      scrollWheelZoom: editable ? true : "center",
      // In the viewer a one-finger drag over the map is the page's: the panel scrolls.
      dragging: editable || !L.Browser.mobile
    })
    this.map.attributionControl.setPrefix(false)

    L.tileLayer(el.dataset.tiles, {
      attribution: el.dataset.attribution,
      maxZoom: 19,
      crossOrigin: true
    }).addTo(this.map)

    if (editable) {
      this.map.on("click", (event) => this.pin(event.latlng, true))
    }

    this.place()
  },

  // Shows what the data attributes say: a pin, a circle, or just the map at its centre.
  place() {
    if (!this.map) return
    const el = this.el
    const lat = number(el.dataset.lat)
    const lon = number(el.dataset.lon)
    const radius = number(el.dataset.radius)
    const center = triple(el.dataset.center)

    if (this.marker) this.marker.remove()
    if (this.circle) this.circle.remove()
    this.marker = this.circle = null

    if (lat !== null && lon !== null && radius) {
      this.circle = L.circle([lat, lon], {
        radius,
        color: "oklch(65% .22 25)",
        weight: 2,
        fillOpacity: 0.15
      }).addTo(this.map)
      this.map.fitBounds(this.circle.getBounds(), { padding: [12, 12] })
    } else if (lat !== null && lon !== null) {
      this.pin({ lat, lng: lon }, false)
      this.map.setView([lat, lon], center ? center[2] : 14)
    } else if (center) {
      this.map.setView([center[0], center[1]], center[2])
    } else {
      const fallback = triple(el.dataset.defaultCenter) || [30, 10, 2]
      this.map.setView([fallback[0], fallback[1]], fallback[2])
    }
  },

  pin(latlng, chosen) {
    const editable = this.el.dataset.editable === "true"

    if (this.marker) {
      this.marker.setLatLng(latlng)
    } else {
      this.marker = L.marker(latlng, { icon: pinIcon(), draggable: editable, keyboard: false }).addTo(
        this.map
      )
      if (editable) {
        this.marker.on("dragend", () => this.send(this.marker.getLatLng()))
      }
    }

    if (chosen) this.send(latlng)
  },

  send(latlng) {
    const lon = L.Util.wrapNum(latlng.lng, [-180, 180], true)
    // To the component the map is drawn in: the info panel.
    this.pushEventTo(this.el, "place_pin", { lat: Number(latlng.lat.toFixed(6)), lon: Number(lon.toFixed(6)) })
  }
}
