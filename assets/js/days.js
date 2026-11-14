// The days of a library, as the calendar's day sheet needs them: where each starts among
// the timeline's positions, how many it holds, and the windows (day ids, `"2022-02-24"` and,
// for a long day, `"2022-02-24:200"`…) its photos arrive in. Pure: the index's sections in,
// days out.

/** The date a window id is of: `"2022-02-24:200"` → `"2022-02-24"`. */
export function dateOf(windowId) {
  return String(windowId || "").slice(0, 10)
}

/** `"2022-02-24"` or `"2022-02"` → `"2022-02"`. */
export function monthOf(date) {
  return String(date || "").slice(0, 7)
}

/**
 * Every day with photos, oldest first: `{ date, start, count, windows, sizes }` (`sizes`:
 * how many photos each window holds). `start` is the
 * timeline position of its first photo (the order of the sections' `days_list`, the same
 * positions the swipe viewer counts in).
 */
export function daysOf(sections) {
  const days = []
  let position = 0
  for (const section of sections || []) {
    for (const window of section.days_list || []) {
      const date = dateOf(window.id)
      const count = window.count || 0
      const last = days[days.length - 1]
      if (last && last.date === date && last.start + last.count === position) {
        last.count += count
        last.windows.push(window.id)
        last.sizes.push(count)
      } else {
        days.push({ date, start: position, count, windows: [window.id], sizes: [count] })
      }
      position += count
    }
  }
  return days
}

/** The day `date` (`"2022-02-24"`), or null when it has no photos. */
export function dayOn(days, date) {
  return days.find((day) => day.date === date) || null
}

/** The day holding timeline position `position`, or null. */
export function dayAt(days, position) {
  let low = 0
  let high = days.length - 1
  while (low <= high) {
    const mid = (low + high) >> 1
    const day = days[mid]
    if (position < day.start) high = mid - 1
    else if (position >= day.start + day.count) low = mid + 1
    else return day
  }
  return null
}

/** The day with photos before (`step` -1) or after (+1) `date`, or null. */
export function neighbour(days, date, step) {
  const index = days.findIndex((day) => day.date === date)
  if (index < 0) return null
  return days[index + step] || null
}

/**
 * Where a date stands in the sections: `{ section, item }`, the first section holding that
 * day (or, for a month, `"2022-02"`, its first day) and the place of its first photo in it.
 * Null for a date with no photos in or after it in that month.
 */
export function placeOf(sections, date) {
  const month = date.length === 7
  for (let s = 0; s < (sections || []).length; s++) {
    let item = 0
    for (const window of sections[s].days_list || []) {
      const day = dateOf(window.id)
      if (month ? monthOf(day) === date : day === date) return { section: s, item }
      item += window.count || 0
    }
  }
  return null
}
