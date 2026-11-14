// Chapters in the timeline: the banner a section that opens a chapter wears over its days, and
// the chips a month header wears inside a chapter or just after one. DOM only, no LiveView: the
// hook places the node and says what to do with a click.
//
// Everything a person typed goes in with textContent, and a colour is a class from a fixed list
// (`pkt-chapter--sky` …): nothing reaches a style attribute.

export const CHAPTER_COLORS = ["sky", "rose", "amber", "emerald", "violet", "slate"]

const EDIT_ICON =
  '<svg aria-hidden="true" viewBox="0 0 20 20" width="16" height="16" fill="currentColor">' +
  '<path d="M13.6 3.2a2 2 0 0 1 2.8 2.8l-.8.8-2.8-2.8.8-.8ZM11.7 5.1 3.5 13.3a2 2 0 0 0-.5.9l-.7 2.9a.5.5 0 0 0 .6.6l2.9-.7a2 2 0 0 0 .9-.5l8.2-8.2-3.2-3.2Z"/></svg>'

/** The class of a chapter's colour; an unknown name gets the first. */
export function colorClass(color) {
  return `pkt-chapter--${CHAPTER_COLORS.includes(color) ? color : CHAPTER_COLORS[0]}`
}

/** "✈️ Trip to France", or the title alone. */
export function chapterName(chapter) {
  return [chapter?.emoji, chapter?.title].filter(Boolean).join(" ")
}

/** A string with `%{name}` holes filled. */
function fill(template, values) {
  return String(template || "").replace(/%\{(\w+)\}/g, (_, key) => values[key] ?? "")
}

/** What a banner shows, as one string: a change of any of it redraws the banner. */
export function bannerKey(section, editable) {
  const c = section.chapter || {}
  return JSON.stringify([c.id, c.title, c.emoji, c.description, c.color, c.dates, c.count_text, c.cover,
    c.parent?.title, c.parent?.emoji, editable])
}

/**
 * Fill `node` (the section's header) with the banner of `section.chapter`.
 * `onEdit(id)` is called by the pencil and by a click on the card; null when the reader may not
 * change chapters (then there is neither).
 */
export function drawBanner(node, section, { strings = {}, onEdit = null } = {}) {
  const chapter = section.chapter
  node.replaceChildren()
  node.className = `pkt-header pkt-banner-host ${colorClass(chapter.color)}${chapter.sub ? " pkt-banner--sub" : ""}`

  const card = document.createElement("div")
  card.className = "pkt-banner"
  if (onEdit) {
    card.dataset.chapterEdit = chapter.id
    card.addEventListener("click", (event) => {
      event.stopPropagation()
      onEdit(chapter.id)
    })
  }

  const cover = document.createElement("div")
  cover.className = "pkt-banner-cover"
  const emoji = document.createElement("span")
  emoji.className = "pkt-banner-emoji"
  emoji.textContent = chapter.emoji || "◆"
  cover.append(emoji)
  if (chapter.cover) {
    const img = document.createElement("img")
    img.alt = ""
    img.decoding = "async"
    img.loading = "lazy"
    img.addEventListener("error", () => img.remove())
    img.src = chapter.cover
    cover.append(img)
    if (chapter.emoji) {
      const badge = document.createElement("span")
      badge.className = "pkt-banner-badge"
      badge.textContent = chapter.emoji
      cover.append(badge)
    }
  }

  const text = document.createElement("div")
  text.className = "pkt-banner-text"
  const kicker = document.createElement("div")
  kicker.className = "pkt-banner-kicker"
  kicker.textContent = chapter.sub && chapter.parent
    ? fill(strings.sub || "Part of %{chapter}", { chapter: chapterName(chapter.parent) })
    : strings.chapter || "Chapter"
  const title = document.createElement("div")
  title.className = "pkt-banner-title"
  title.textContent = chapter.title
  const meta = document.createElement("div")
  meta.className = "pkt-banner-meta"
  meta.textContent = [chapter.dates, chapter.count_text].filter(Boolean).join(" · ")
  text.append(kicker, title, meta)
  if (chapter.description && !chapter.sub) {
    const description = document.createElement("div")
    description.className = "pkt-banner-desc"
    description.textContent = chapter.description
    text.append(description)
  }
  card.append(cover, text)

  if (onEdit) {
    const edit = document.createElement("span")
    edit.className = "pkt-banner-edit"
    edit.setAttribute("role", "button")
    edit.setAttribute("aria-label", strings.edit || "Edit chapter")
    edit.title = strings.edit || "Edit chapter"
    edit.innerHTML = EDIT_ICON
    card.append(edit)
  }
  node.append(card)
  return card
}

/**
 * The chips of a month header: the chapters it is inside, and the one that just ended.
 * `onJump(id)` goes to a chapter's banner.
 */
export function drawChips(node, section, { strings = {}, onJump = null } = {}) {
  for (const old of node.querySelectorAll(".pkt-chip")) old.remove()
  const chips = []
  for (const chapter of section.within || []) chips.push({ chapter, text: chapterName(chapter) })
  if (section.after) {
    chips.push({
      chapter: section.after,
      text: fill(strings.after || "after %{chapter}", { chapter: chapterName(section.after) }),
      after: true
    })
  }
  const before = node.querySelector("[data-section-select]")
  for (const { chapter, text, after } of chips) {
    const chip = document.createElement("button")
    chip.type = "button"
    chip.className = `pkt-chip ${colorClass(chapter.color)}${after ? " pkt-chip--after" : ""}`
    chip.textContent = text
    if (onJump) chip.addEventListener("click", (event) => {
      event.stopPropagation()
      onJump(chapter.id)
    })
    node.insertBefore(chip, before)
  }
}

/** What the chips show, as one string. */
export function chipsKey(section) {
  return JSON.stringify([(section.within || []).map(c => [c.id, c.title, c.emoji, c.color]),
    section.after && [section.after.id, section.after.title, section.after.emoji, section.after.color]])
}
