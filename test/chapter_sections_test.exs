defmodule PhoenixKitPhotos.ChapterSectionsTest do
  @moduledoc """
  How chapters cut a library's months into the timeline's sections: a banner section where a
  chapter starts, a new section after it ends, sub-chapters after their chapter, chips for the
  chapters a month is inside, and the days of a month each part covers.
  """
  use ExUnit.Case, async: true

  alias PhoenixKitPhotos.Chapter
  alias PhoenixKitPhotos.ChapterSections

  defp days(list),
    do: Enum.map(list, fn {d, n} -> %{taken_on: d, count: n, sum_aspect: n * 1.5} end)

  defp chapter(id, from, to, attrs \\ %{}) do
    struct(
      %Chapter{uuid: id, title: "Chapter #{id}", starts_on: from, ends_on: to, color: "sky"},
      attrs
    )
  end

  defp shape(sections), do: Enum.map(sections, &{&1.id, &1.dates, &1.span})

  test "no chapters: months as before, with their month and no span" do
    sections =
      ChapterSections.build(
        days([{~D[2026-07-01], 2}, {~D[2026-07-20], 3}, {~D[2026-08-02], 1}]),
        []
      )

    assert [
             %{id: "2026-07", month: "2026-07", span: nil, count: 5, chapter: nil, within: []},
             %{id: "2026-08", count: 1}
           ] = sections

    assert hd(sections).dates == [~D[2026-07-01], ~D[2026-07-20]]
  end

  test "a trip in the middle of a month cuts it in three" do
    rows =
      days([{~D[2026-07-02], 1}, {~D[2026-07-12], 4}, {~D[2026-07-15], 2}, {~D[2026-07-25], 3}])

    trip = chapter("t", ~D[2026-07-12], ~D[2026-07-20])

    sections = ChapterSections.build(rows, [trip])

    assert shape(sections) == [
             {"2026-07", [~D[2026-07-02]], [1, 11]},
             {"c:t", [~D[2026-07-12], ~D[2026-07-15]], [12, 20]},
             {"2026-07~2", [~D[2026-07-25]], [21, 31]}
           ]

    [before, banner, back] = sections
    assert before.chapter == nil
    assert banner.chapter.title == "Chapter t"
    assert banner.chapter.count == 6
    assert banner.chapter.count_text == "6 photos"
    assert banner.chapter.dates == "12–20 July 2026"
    assert banner.count == 6
    assert back.after.id == "t"
    assert back.within == []
  end

  test "a chapter across a month's end: the next month's header is inside it" do
    rows = days([{~D[2026-07-30], 1}, {~D[2026-08-02], 2}, {~D[2026-08-10], 1}])
    trip = chapter("t", ~D[2026-07-29], ~D[2026-08-03])

    sections = ChapterSections.build(rows, [trip])

    assert shape(sections) == [
             {"c:t", [~D[2026-07-30]], [29, 31]},
             {"2026-08", [~D[2026-08-02]], [1, 3]},
             {"2026-08~2", [~D[2026-08-10]], [4, 31]}
           ]

    assert Enum.at(sections, 1).within |> Enum.map(& &1.id) == ["t"]
    # The end was in August, the part after it too: "after" it.
    assert Enum.at(sections, 2).after.id == "t"
  end

  test "a chapter starting where there are no photos takes the month of its first one" do
    rows = days([{~D[2026-07-05], 1}, {~D[2026-08-02], 2}])
    trip = chapter("t", ~D[2026-07-30], ~D[2026-08-04])

    assert [%{id: "2026-07"}, %{id: "c:t", month: "2026-08", dates: [~D[2026-08-02]], span: nil}] =
             ChapterSections.build(rows, [trip])
  end

  test "a chapter with no photos yet still has its banner, at its date" do
    rows = days([{~D[2026-07-05], 1}])
    trip = chapter("t", ~D[2026-11-14], nil)

    assert [%{id: "2026-07"}, %{id: "c:t", count: 0, dates: [], chapter: banner}] =
             ChapterSections.build(rows, [trip])

    assert banner.dates == "since 14 November 2026"
    assert banner.count == nil
  end

  test "a chapter without an end runs its section to the month's end, and nothing is inside it" do
    rows = days([{~D[2026-07-05], 1}, {~D[2026-07-20], 1}, {~D[2026-08-01], 1}])
    moved = chapter("m", ~D[2026-07-10], nil)

    assert [
             %{id: "2026-07", span: [1, 9]},
             %{id: "c:m", span: [10, 31], dates: [~D[2026-07-20]]},
             %{id: "2026-08", within: [], after: nil}
           ] = ChapterSections.build(rows, [moved])
  end

  test "sub-chapters: the chapter's banner, then each sub-chapter's, chips name both" do
    rows =
      days([
        {~D[2026-07-12], 2},
        {~D[2026-07-14], 1},
        {~D[2026-07-17], 3},
        {~D[2026-07-19], 1}
      ])

    trip = chapter("t", ~D[2026-07-12], ~D[2026-07-20], %{emoji: "✈️"})
    paris = chapter("p", ~D[2026-07-12], ~D[2026-07-15], %{parent_uuid: "t"})
    nice = chapter("n", ~D[2026-07-17], ~D[2026-07-18], %{parent_uuid: "t"})

    sections = ChapterSections.build(rows, [trip, paris, nice])

    # Nothing between Paris and Nice: no empty section between their banners.
    assert Enum.map(sections, & &1.id) == ["c:t", "c:p", "c:n", "2026-07"]

    [t, p, n, rest] = sections
    assert t.dates == [] and t.chapter.sub == false
    assert p.dates == [~D[2026-07-12], ~D[2026-07-14]]
    assert p.chapter.sub and p.chapter.parent.title == "Chapter t"
    # The sub-chapter's banner names its chapter: no chip for it.
    assert p.within == []
    assert n.dates == [~D[2026-07-17]]
    assert rest.dates == [~D[2026-07-19]]
    assert rest.within |> Enum.map(& &1.id) == ["t"]
    assert rest.after.id == "n"
    assert t.chapter.count == 7
    assert p.chapter.count == 3
  end

  test "every photo is in exactly one section, in order" do
    rows = days(for d <- 1..31, do: {Date.new!(2026, 7, d), 1})

    chapters = [
      chapter("a", ~D[2026-07-03], ~D[2026-07-09]),
      chapter("b", ~D[2026-07-05], ~D[2026-07-06], %{parent_uuid: "a"}),
      chapter("c", ~D[2026-07-20], nil),
      chapter("d", ~D[2026-07-25], ~D[2026-08-02])
    ]

    sections = ChapterSections.build(rows, chapters)
    assert sections |> Enum.flat_map(& &1.dates) == Enum.map(rows, & &1.taken_on)
    assert Enum.sum(Enum.map(sections, & &1.count)) == 31
    assert sections |> Enum.map(& &1.id) |> Enum.uniq() |> length() == length(sections)
  end

  describe "dates_text/2" do
    test "the shapes of a chapter's days" do
      assert ChapterSections.dates_text(~D[2026-07-12], ~D[2026-07-12]) == "12 July 2026"
      assert ChapterSections.dates_text(~D[2026-07-12], ~D[2026-07-20]) == "12–20 July 2026"

      assert ChapterSections.dates_text(~D[2026-07-28], ~D[2026-08-03]) ==
               "28 July – 3 August 2026"

      assert ChapterSections.dates_text(~D[2025-12-28], ~D[2026-01-03]) ==
               "28 December 2025 – 3 January 2026"

      assert ChapterSections.dates_text(~D[2026-07-12], nil) == "since 12 July 2026"
    end
  end
end
