// What the calendar style draws besides the tiles: the weekdays, a square for every day, the
// day numbers, and "+N" over the last photo of a day that has more than its square shows. The
// shape is in layouts.js (`layout.calendar`); this only turns it into nodes, two a month: one
// behind the tiles and one in front of them. Neither takes a pointer, so a click on a number or
// on a "+N" opens the photo under it.

/**
 * The locale whose week a calendar follows: the browser's own, when it is the page's language
 * (an English page read in Britain starts on Monday), else the page's.
 */
export function weekLocale(lang, browser = []) {
  const base = (lang || "").split("-")[0].toLowerCase()
  const own = browser.find(tag => tag && tag.split("-")[0].toLowerCase() === base && tag.includes("-"))
  return own || lang || browser[0] || "en"
}

/** The first day of the week where a locale is spoken: 0 Sunday … 6 Saturday. */
export function weekStartFor(lang) {
  try {
    const locale = new Intl.Locale(lang || "en")
    const info = locale.getWeekInfo?.() || locale.weekInfo
    if (info && info.firstDay) return info.firstDay % 7
  } catch (_error) {
    // An unknown tag, or a browser without Intl.Locale: Monday, as most of the world.
  }
  return 1
}

/** Seven weekday names from `weekStart`, short or (for narrow days) a letter. */
export function weekdayNames(lang, weekStart, narrow) {
  let format
  try {
    format = new Intl.DateTimeFormat(lang || undefined, { weekday: narrow ? "narrow" : "short", timeZone: "UTC" })
  } catch (_error) {
    format = new Intl.DateTimeFormat(undefined, { weekday: narrow ? "narrow" : "short", timeZone: "UTC" })
  }
  // 2024-01-07 was a Sunday.
  return Array.from({ length: 7 }, (_, i) => format.format(new Date(Date.UTC(2024, 0, 7 + ((weekStart + i) % 7)))))
}

/** Today in the browser's own time zone, as the `{ year, month, day }` of a calendar. */
export function today(now = new Date()) {
  return { year: now.getFullYear(), month: now.getMonth() + 1, day: now.getDate() }
}

function box(className, { x, y, w, h }, text) {
  const node = document.createElement("div")
  node.className = className
  node.style.left = `${x}px`
  node.style.top = `${y}px`
  node.style.width = `${w}px`
  node.style.height = `${h}px`
  if (text !== undefined) node.textContent = text
  return node
}

/** Fill a month's two nodes from its layout. */
export function drawCalendar(back, front, layout, { lang, now } = {}) {
  const { month, weekStart, weekday, dayW, cells } = layout.calendar
  const names = weekdayNames(lang, weekStart, dayW < 44)
  const step = dayW + layout.calendar.space
  const day = now || today()
  const thisMonth = day.year === month.year && day.month === month.month
  const weekend = (weekdayIndex) => weekdayIndex === 0 || weekdayIndex === 6

  const backNodes = names.map((name, i) =>
    box(`pkt-cal-wd${weekend((weekStart + i) % 7) ? " pkt-cal-weekend" : ""}`, { x: i * step, y: weekday.y, w: dayW, h: weekday.h }, name)
  )
  const frontNodes = []

  for (const cell of cells) {
    const classes = ["pkt-cal-day"]
    if (cell.count > 0) classes.push("pkt-cal-full")
    if (weekend(cell.weekday)) classes.push("pkt-cal-weekend")
    if (thisMonth && cell.day === day.day) classes.push("pkt-cal-today")
    if (cell.future) classes.push("pkt-cal-future")
    const square = box(classes.join(" "), cell)
    const number = document.createElement("span")
    number.className = "pkt-cal-num"
    number.textContent = String(cell.day)
    square.append(number)
    ;(cell.count > 0 ? frontNodes : backNodes).push(square)

    if (cell.more > 0 && cell.last) {
      // Over the last of several photos, a dark "+N"; a day of one photo (a phone, zoomed in)
      // keeps it whole and wears the count in a corner.
      const shown = cell.count - cell.more
      if (shown > 1 && cell.last.w >= 56) {
        const more = box("pkt-cal-more", cell.last, `+${cell.more}`)
        more.style.fontSize = `${Math.round(Math.max(10, Math.min(16, cell.last.h * 0.3)))}px`
        frontNodes.push(more)
      } else {
        square.append(Object.assign(document.createElement("span"), { className: "pkt-cal-count", textContent: `+${cell.more}` }))
      }
    }
  }

  back.replaceChildren(...backNodes)
  front.replaceChildren(...frontNodes)
}
