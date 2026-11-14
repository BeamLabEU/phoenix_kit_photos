# Calendar and view addresses: a day of the calendar, and links to a place in time

Decided with the owner and built on 2026-11-14 (see **What was built** at the end).

## What the owner asked (2026-11-14)

> Calendar view is amazing. One problem: a day with 13 items shows them, but a click on
> the day gives the first item of that day. This view should be in the URL, the same as a
> map view of the whole library will be: someone who finds a library and looks at its map
> (or calendar) should be able to send that view. For other views nothing special, but we
> will need to copy a link to a particular place in time (probably for any view).

> If this is my library `https://fotki.ee/en/fotkin/russo-ukrainian-war`, the calendar view
> could be `…/russo-ukrainian-war/v/calendar`, and a click on a date gives that day,
> `…/v/calendar/2002-03-03/`. Then if a person clicks a single item, they somehow lose the
> calendar; not sure how to do this better.

## Where things stand

- The style (grid, rows, …, calendar) is chosen in the browser only: `localStorage`
  `phoenix_kit_photos:style`, read by `photo_timeline.js` (`startingStyle`). Nothing of
  it is in the address.
- In the calendar, a click on a day opens the photo under the pointer in the swipe
  viewer; "+N" opens the last photo shown. The viewer then swipes through the whole
  library, not the day.
- Addresses today: `/<username>/<library>` and `/<username>/<library>/p/<code>`
  (Fotki's `FotkiWeb.PhotosLive`, routed after `phoenix_kit_routes()`, one literal route
  per language code for the short shapes). The viewer keeps the address in step through
  `JS.patch`; the parent tells the timeline which photo the address names (`push_view`).
- The timeline has no date filter: a day page needs a new scope ("this library, this
  day") in `Timeline` and `PhotoTimeline`.

## Proposal (from the first answer on)

| Address | Shows |
|---|---|
| `/<user>/<lib>` | the timeline, in the person's own look (as today) |
| `/<user>/<lib>/2022-02-24` (or `/2022-02`) | the timeline scrolled to that day (month) |
| `/<user>/<lib>/v/calendar` | the calendar |
| `/<user>/<lib>/v/calendar/2022-02` | the calendar at that month |
| `/<user>/<lib>/v/calendar/2022-02-24` | that day's sheet over the calendar |
| `/<user>/<lib>/v/map…` | later, the map, same pattern |

Only calendar and map are *views* with addresses; the other looks (grid, mosaic, film…)
stay a personal preference. A "Copy link to here" action gives the place-in-time address
of whatever is on screen.

## Decisions

- **D1. The day is a sheet over the calendar** (owner, 2026-11-14). The month stays
  visible, dimmed, behind; the sheet holds all the day's photos as a grid, with ‹ › to
  the previous/next day that has photos and ✕. Close or Back returns to the month where
  the person was.

- **D2. A photo opened from a day has an in-day address**,
  `/<user>/<lib>/v/calendar/2022-02-24/p/<code>` (owner, 2026-11-14). The viewer swipes
  that day only ("3 of 13"); ✕ returns to the day's sheet, Back to the month. A shared
  link rebuilds calendar → day → photo.
  **No duplicate content** (owner's condition): an in-day photo page carries
  `<link rel="canonical">` to the photo's own `/p/<code>` (and no `noindex`, which with a
  canonical is a mixed signal); the view pages (`/v/…`, dated timeline addresses) carry
  `<meta name="robots" content="noindex, follow">`; none of these shapes ever enters a
  sitemap. To check: what core's sitemap module lists for libraries and photos today, and
  that the root layout's Open Graph / share tags use the canonical address.

- **D3. Views have their own switcher** (owner, 2026-11-14): a toggle in the library's
  header, Timeline | Calendar now, with Map certain and maybe People and others to come,
  each view its own address (`/v/<view>`). The style menu keeps only the looks (Grid,
  Rows, Mosaic, Film…) and belongs to Timeline. The switcher is built for a growing list
  (a segmented toggle while there are few, a menu when there are more); Calendar leaves
  the style menu, and a person whose stored style is `calendar` starts on Timeline's grid.

- **D4. A place-in-time link is asked for, not followed** (owner, 2026-11-14): the address
  bar keeps the library's address while scrolling. *Copy link to here* (in the month
  heading's menu, and in Share) copies the dated address of what is on screen
  (`/<user>/<lib>/2022-02-24` in Timeline, `/v/calendar/2022-02` in Calendar). Sharing the
  library still shares it from the start.

## Build order (proposed)

1. Fotki routes for `/v/<view>`, `/v/<view>/<date>`, `/v/calendar/<day>/p/<code>` and
   `/<date>` (each language prefix too); `v` and date-shaped slugs reserved; `PhotosLive`
   reads view, date and day and hands them to the timeline; canonical / robots tags (D2).
2. `Timeline`/`PhotoTimeline`: a day scope (one library, one `taken_on`) for the sheet and
   the in-day viewer; the opening position from an address (`jumpTo` a day).
3. The views switcher (D3) and Calendar out of the style menu.
4. The day sheet (D1): grid, ‹ › to neighbouring days with photos, ✕/Back; the viewer
   bound to the day (D2).
5. *Copy link to here* (D4).
6. Tests (LiveView, JS `node --test`), a browser check in `test/browser/`, et/ru.

## Open

- What "Copy link to here" sits on, in each view.
- Language-prefixed routes for the new shapes (`/et/<user>/<lib>/v/calendar…`), reserved
  names (`v` as a library slug).

## What was built (2026-11-14)

- **Fotki addresses** (`FotkiWeb.Router`, `FotkiWeb.PhotoPaths.place/1`, `place_suffix/1`,
  `photo_in/4`, `view_template/2`): `/v/calendar`, `/v/calendar/<month>`,
  `/v/calendar/<day>`, `/v/calendar/<day>/p/<code>`, `/<user>/<library>/<date>`, each with a
  language. A library in a language is now a literal route per code
  (`/et/:username/:library`), since `/<user>/<library>/<date>` has its shape; `p` and `v` are
  reserved library slugs. A wrong view, date or day is the site's 404 page; a photo asked for
  from a day it was not taken on goes to its `/p/<code>`.
- **Search engines** (D2): an in-day photo has `<link rel="canonical">` to its `/p/<code>`
  (and its `og:url`); views and dated places have `noindex, follow`. Nothing is in a sitemap
  (Fotki has none of these shapes). Still to check: core's sitemap module, if it is ever
  switched on for libraries.
- **The timeline** (`PhotoTimeline`'s `view_path` and `place`, `push_view/6` `place:`): the
  views switcher (D3; icons on a phone), Calendar out of the style menu, the place applied in
  the browser (`applyPlace`: the view, the date to stand at, the day's sheet), and an echo of
  an address the hook set itself moves nothing.
- **The day sheet** (D1, `assets/js/day_sheet.js`, days in `assets/js/days.js`): all of the
  day's photos, ‹ › (and ←/→) to the days around it with photos, ✕/Escape/the dimmed month back
  to the month (Back when the sheet added the history entry, else the month's address).
- **The viewer bound to the day** (D2, `boundPager` in `photo_timeline.js`): the engine gets
  the day's slice of the list and the hook's indices are translated, so nothing else in the
  hook changed. Over the sheet it flies back to the sheet's tile.
- **Copy link to here** (D4): a link button beside the switcher (hidden on a phone, where the
  row is full), copying the sheet's day, the calendar's month or the timeline's day on
  screen. Not yet in the header's Share, as D4 also named.
- Found on the way: LiveView patches the viewport's own attributes despite
  `phx-update="ignore"` and dropped `data-active-style`, which the looks' CSS reads; the
  hook's `updated()` puts it back.
- Tests: Fotki `test/fotki_web/live/library_views_test.exs`, the package's `days.test.js`
  and `PhotoTimeline.place/1`; browser check `test/browser/calendar_views.mjs` (Fotki) with
  `scripts/upload_browser_host.exs`.

