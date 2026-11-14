defmodule PhoenixKitPhotos.ChapterSections do
  @moduledoc """
  The timeline's sections when a library has chapters (`PhoenixKitPhotos.Chapter`): months,
  cut where a chapter starts and on the day after one ends. Pure: day rows and chapters in,
  sections out, so it is tested without a database.

  A section that opens a chapter has the id `"c:<chapter uuid>"` and carries the chapter
  (`chapter`), which the browser draws as a banner over its days; a chapter's start falling
  between two days with photos still gets its section (a trip that has just begun, with none
  yet). The days after a cut get a section of their own (`"2026-07~2"`), with the chapters
  they are inside in `within` and, right after a chapter ended in the same month, that
  chapter in `after`. Every section says which month it is in (`month`) and, when it is not
  the whole month, which of its days it covers (`span`, `[first, last]`): the calendar style
  draws those weeks only.

  Several chapters starting on one day open a section each, a chapter before its
  sub-chapters, so a trip's banner comes before the banner of its first city.
  """

  use Gettext, backend: PhoenixKitPhotos.Gettext

  alias PhoenixKitPhotos.Chapter
  alias PhoenixKitPhotos.Timeline

  @doc """
  Sections for `day_rows` (`%{taken_on, count, sum_aspect}`, by day) and the library's
  `chapters`. Each section also has `dates`, its days, which is not for the browser.
  """
  def build(day_rows, []), do: Timeline.group_days(day_rows) |> Enum.map(&plain_month/1)

  def build(day_rows, chapters) do
    by_uuid = Map.new(chapters, &{&1.uuid, &1})
    counts = Map.new(day_rows, &{&1.taken_on, &1.count})

    marks =
      Enum.flat_map(chapters, fn chapter ->
        start = [{chapter.starts_on, 1, chapter}]
        if chapter.ends_on, do: [{Date.add(chapter.ends_on, 1), 0, chapter} | start], else: start
      end)

    days = Enum.map(day_rows, &{&1.taken_on, 2, &1})

    # By date; on a date the ends come first, then the starts (a chapter before its
    # sub-chapters, as listed), then the photos.
    events =
      (marks ++ days)
      |> Enum.with_index()
      |> Enum.sort_by(fn {{date, kind, _}, i} -> {Date.to_gregorian_days(date), kind, i} end)
      |> Enum.map(&elem(&1, 0))

    state = %{done: [], current: nil, seq: %{}, ended: nil}

    %{done: done, current: current} = Enum.reduce(events, state, &step/2)

    [current | done]
    |> Enum.reject(&is_nil/1)
    |> Enum.reverse()
    |> spans()
    |> Enum.map(&finish(&1, chapters, by_uuid, counts))
  end

  # ── Walking the dates ─────────────────────────────────────────────────────

  # A chapter ended: what follows is cut from what came before.
  defp step({date, 0, chapter}, %{current: current} = state) do
    if current,
      do: %{state | current: %{current | sealed: true}, ended: {chapter, date}},
      else: state
  end

  # A chapter starts: a section of its own.
  defp step({date, 1, chapter}, state) do
    state = close(state)
    %{state | current: new_section("c:" <> chapter.uuid, month_of(date), date, chapter)}
  end

  defp step({date, 2, row}, %{current: current} = state) do
    month = month_of(date)

    state =
      cond do
        # A chapter's section with no photos yet takes the month of its first one.
        current && current.chapter && current.dates == [] && !current.sealed ->
          %{state | current: %{current | month: month}}

        current && !current.sealed && current.month == month ->
          state

        true ->
          open_plain(state, month, date)
      end

    %{state | current: add_day(state.current, row)}
  end

  defp open_plain(state, month, date) do
    after_chapter =
      case {state.current, state.ended} do
        {%{sealed: true, month: ^month}, {chapter, _}} -> chapter
        _ -> nil
      end

    # A new month starts on its first day; a cut on the day the chapter ended.
    start =
      case state.ended do
        {_chapter, cut} when after_chapter != nil -> cut
        _ -> if month_of(date) == month, do: Date.beginning_of_month(date), else: date
      end

    state = close(state)
    {id, seq} = plain_id(state.seq, month)

    section = %{new_section(id, month, start, nil) | after: after_chapter}
    %{state | current: section, seq: seq, ended: nil}
  end

  defp close(%{current: nil} = state), do: state

  defp close(%{current: current, done: done} = state),
    do: %{state | done: [current | done], current: nil}

  defp new_section(id, month, start, chapter) do
    %{
      id: id,
      month: month,
      start: start,
      chapter: chapter,
      after: nil,
      sealed: false,
      dates: [],
      rows: []
    }
  end

  defp add_day(section, row),
    do: %{section | dates: [row.taken_on | section.dates], rows: [row | section.rows]}

  # The first plain section of a month has the month's id, as without chapters.
  defp plain_id(seq, month) do
    n = Map.get(seq, month, 0) + 1
    {if(n == 1, do: month, else: "#{month}~#{n}"), Map.put(seq, month, n)}
  end

  # ── Spans: which days of its month a section covers ──────────────────────

  defp spans(sections) do
    next_starts = sections |> Enum.drop(1) |> Enum.map(&{&1.month, &1.start}) |> Kernel.++([nil])

    Enum.zip_with(sections, next_starts, fn section, next ->
      {first_date, last_date} = month_bounds(section.month)

      from =
        if month_of(section.start) == section.month, do: section.start.day, else: first_date.day

      to =
        case next do
          {month, start} when month == section.month ->
            max(from, Date.add(start, -1).day)

          _ ->
            last_date.day
        end

      span = if from == 1 and to == last_date.day, do: nil, else: [from, to]
      Map.put(section, :span, span)
    end)
  end

  defp month_bounds(<<y::binary-size(4), "-", m::binary-size(2)>>) do
    first = Date.new!(String.to_integer(y), String.to_integer(m), 1)
    {first, Date.end_of_month(first)}
  end

  # ── The section as the timeline gives it ─────────────────────────────────

  defp finish(section, chapters, by_uuid, counts) do
    rows = Enum.reverse(section.rows)
    dates = Enum.reverse(section.dates)
    probe = List.first(dates) || section.start

    within =
      chapters
      |> Enum.filter(fn chapter ->
        own = section.chapter

        chapter.ends_on != nil and chapter != own and Chapter.covers?(chapter, probe) and
          not (own != nil and own.parent_uuid == chapter.uuid)
      end)
      |> Enum.map(&chip/1)

    %{
      id: section.id,
      label: Timeline.month_label(section.month),
      month: section.month,
      span: section.span,
      count: Enum.reduce(rows, 0, &(&1.count + &2)),
      sum_aspect: Enum.reduce(rows, 0.0, &(&2 + to_float(&1.sum_aspect))),
      days: length(rows),
      days_list: Enum.flat_map(rows, &Timeline.day_windows/1),
      dates: dates,
      chapter: section.chapter && banner(section.chapter, by_uuid, counts),
      within: within,
      after: section.after && chip(section.after)
    }
  end

  defp plain_month(section) do
    section
    |> Map.merge(%{month: section.id, span: nil, chapter: nil, within: [], after: nil})
    |> Map.put(
      :dates,
      Enum.map(section.days_list, &String.slice(&1.id, 0, 10))
      |> Enum.uniq()
      |> Enum.map(&Date.from_iso8601!/1)
    )
  end

  @doc "What a chip says of a chapter: its id, title, emoji and colour."
  def chip(%Chapter{} = chapter) do
    %{id: chapter.uuid, title: chapter.title, emoji: chapter.emoji, color: color(chapter)}
  end

  defp banner(%Chapter{} = chapter, by_uuid, counts) do
    parent = chapter.parent_uuid && by_uuid[chapter.parent_uuid]

    %{
      id: chapter.uuid,
      title: chapter.title,
      emoji: chapter.emoji,
      description: chapter.description,
      color: color(chapter),
      starts_on: Date.to_iso8601(chapter.starts_on),
      ends_on: chapter.ends_on && Date.to_iso8601(chapter.ends_on),
      dates: dates_text(chapter.starts_on, chapter.ends_on),
      count: photo_count(chapter, counts),
      count_text: count_text(photo_count(chapter, counts)),
      parent: parent && chip(parent),
      sub: parent != nil,
      cover: nil,
      cover_file: chapter.cover_file_uuid
    }
  end

  defp color(%Chapter{color: color}) when is_binary(color), do: color
  defp color(_chapter), do: hd(Chapter.colors())

  defp count_text(nil), do: nil
  defp count_text(0), do: gettext("no photos yet")
  defp count_text(count), do: ngettext("%{count} photo", "%{count} photos", count)

  defp photo_count(%Chapter{ends_on: nil}, _counts), do: nil

  defp photo_count(%Chapter{} = chapter, counts) do
    Enum.reduce(counts, 0, fn {date, count}, sum ->
      if Chapter.covers?(chapter, date), do: sum + count, else: sum
    end)
  end

  # ── Dates as words ────────────────────────────────────────────────────────

  @doc """
  A chapter's days as a person writes them: "12 July 2026", "12–20 July 2026",
  "28 July – 3 August 2026", "28 December 2025 – 3 January 2026", or "since 12 July 2026"
  for one without an end. Translated: the day and the month go together, which is where
  languages differ (Russian "12 июля", Estonian "12. juuli").
  """
  @spec dates_text(Date.t(), Date.t() | nil) :: String.t()
  def dates_text(%Date{} = from, nil),
    do: gettext("since %{date}", date: with_year(day_month(from), from.year))

  def dates_text(%Date{} = from, %Date{} = to) do
    cond do
      from == to ->
        with_year(day_month(from), from.year)

      from.year == to.year and from.month == to.month ->
        with_year(
          gettext("%{from}–%{to}", from: day_alone(from), to: day_month(to)),
          to.year
        )

      from.year == to.year ->
        with_year(gettext("%{from} – %{to}", from: day_month(from), to: day_month(to)), to.year)

      true ->
        gettext("%{from} – %{to}",
          from: with_year(day_month(from), from.year),
          to: with_year(day_month(to), to.year)
        )
    end
  end

  defp with_year(text, year), do: gettext("%{date} %{year}", date: text, year: year)

  defp day_alone(%Date{day: day}), do: gettext("%{day}", day: day)

  defp day_month(%Date{month: 1, day: day}), do: gettext("%{day} January", day: day)
  defp day_month(%Date{month: 2, day: day}), do: gettext("%{day} February", day: day)
  defp day_month(%Date{month: 3, day: day}), do: gettext("%{day} March", day: day)
  defp day_month(%Date{month: 4, day: day}), do: gettext("%{day} April", day: day)
  defp day_month(%Date{month: 5, day: day}), do: gettext("%{day} May", day: day)
  defp day_month(%Date{month: 6, day: day}), do: gettext("%{day} June", day: day)
  defp day_month(%Date{month: 7, day: day}), do: gettext("%{day} July", day: day)
  defp day_month(%Date{month: 8, day: day}), do: gettext("%{day} August", day: day)
  defp day_month(%Date{month: 9, day: day}), do: gettext("%{day} September", day: day)
  defp day_month(%Date{month: 10, day: day}), do: gettext("%{day} October", day: day)
  defp day_month(%Date{month: 11, day: day}), do: gettext("%{day} November", day: day)
  defp day_month(%Date{month: 12, day: day}), do: gettext("%{day} December", day: day)

  defp month_of(%Date{year: year, month: month}),
    do: :io_lib.format("~4..0B-~2..0B", [year, month]) |> IO.iodata_to_binary()

  defp to_float(%Decimal{} = decimal), do: Decimal.to_float(decimal)
  defp to_float(number) when is_integer(number), do: number * 1.0
  defp to_float(number) when is_float(number), do: number
  defp to_float(nil), do: 0.0
end
