defmodule PhoenixKitPhotos.PhotoTimelineChaptersTest do
  @moduledoc """
  The timeline component's side of chapters: the selection bar's Chapter opens the dialog on
  the chosen photos, saving sends a new index with the banner and goes to it, the banner's
  pencil edits and deletes, the jump list names chapters, and a change made elsewhere reaches
  the page.
  """
  use PhoenixKitPhotos.DataCase, async: false
  import Phoenix.LiveViewTest

  alias PhoenixKitPhotos.Chapters

  @endpoint PhoenixKitPhotos.TestEndpoint

  # Core reads a member's role with `String.to_existing_atom/1` (see bulk_test.exs).
  @viewer :viewer

  setup do
    start_supervised!({Phoenix.PubSub, name: PhoenixKitPhotos.TestPubSub})
    start_supervised!(PhoenixKitPhotos.TestEndpoint)
    start_supervised!(PhoenixKit.PubSub.Manager)
    user = user_fixture("chapter-live-#{System.unique_integer([:positive])}@example.com")
    library = library_fixture(user)

    photo = fn day, hh ->
      {:ok, at} = DateTime.new(day, Time.new!(hh, 0, 0))
      file_fixture(user, %{library_uuid: library.uuid, taken_on: day, taken_at: at})
    end

    a = photo.(~D[2026-07-02], 10)
    b = photo.(~D[2026-07-12], 10)
    c = photo.(~D[2026-07-14], 10)
    d = photo.(~D[2026-07-25], 10)

    {:ok, view, _html} =
      live_isolated(Phoenix.ConnTest.build_conn(), PhoenixKitPhotos.TestLive,
        session: %{
          "scope" => scope_for(user),
          "library" => {:library, library.uuid},
          "selectable" => true
        }
      )

    view |> element("#test-timeline-viewport") |> render_hook("timeline:ready", %{})
    assert_push_event(view, "timeline:test-timeline:index", %{hello: true, total: 4})

    %{view: view, user: user, library: library, a: a, b: b, c: c, d: d}
  end

  test "a chapter from the chosen photos: dialog, save, banner, jump", ctx do
    html =
      ctx.view
      |> element("#test-timeline-viewport")
      |> render_hook("timeline:bulk", %{"action" => "chapter", "ids" => [ctx.c.uuid, ctx.b.uuid]})

    assert html =~ "New chapter"
    assert html =~ ~s(value="2026-07-12")
    assert html =~ ~s(value="2026-07-14")

    ctx.view |> element("button[phx-value-emoji='✈️']") |> render_click()

    ctx.view
    |> element("#test-timeline-chapter-form")
    |> render_submit(%{"title" => "Trip to France", "emoji" => "✈️"})

    [chapter] = Chapters.list(ctx.library.uuid)
    assert chapter.title == "Trip to France"
    assert chapter.emoji == "✈️"
    assert chapter.starts_on == ~D[2026-07-12] and chapter.ends_on == ~D[2026-07-14]
    assert chapter.cover_file_uuid == ctx.b.uuid

    # The index pushed after the save (an older one may still be in the mailbox).
    assert_push_event(ctx.view, "timeline:test-timeline:index", %{sections: [_, _, _] = sections})
    ids = Enum.map(sections, & &1.id)
    assert ids == ["2026-07", "c:" <> chapter.uuid, "2026-07~2"]
    banner = Enum.at(sections, 1)
    assert banner.chapter.title == "Trip to France"
    assert banner.chapter.dates == "12–14 July 2026"
    assert banner.span == [12, 14]

    chapter_id = "c:" <> chapter.uuid
    assert_push_event(ctx.view, "timeline:test-timeline:jump", %{id: ^chapter_id})
    assert_push_event(ctx.view, "timeline:test-timeline:selection", %{clear: true})

    html = render(ctx.view)
    refute html =~ "New chapter"
    # The jump list: July once, the chapter by name.
    assert html =~ "◆ ✈️ Trip to France"
    assert length(Regex.scan(~r/>July 2026</, html)) == 1
  end

  test "the banner's pencil: change, add a sub-chapter, delete", ctx do
    {:ok, chapter} =
      Chapters.create(scope_for(ctx.user), ctx.library.uuid, %{
        "title" => "France",
        "starts_on" => "2026-07-10",
        "ends_on" => "2026-07-20"
      })

    html =
      ctx.view
      |> element("#test-timeline-viewport")
      |> render_hook("timeline:chapter_edit", %{"id" => chapter.uuid})

    assert html =~ "Edit chapter"

    html =
      ctx.view
      |> element("#test-timeline-chapter-form")
      |> render_submit(%{"title" => "France", "ends_on" => "2026-07-05"})

    assert html =~ "The end is before the start."

    ctx.view |> element("button", "Add a sub-chapter") |> render_click()
    assert render(ctx.view) =~ "New sub-chapter"

    ctx.view
    |> element("#test-timeline-chapter-form")
    |> render_submit(%{
      "title" => "Paris",
      "starts_on" => "2026-07-12",
      "ends_on" => "2026-07-14"
    })

    assert [%{title: "France"}, %{title: "Paris", parent_uuid: parent}] =
             Chapters.list(ctx.library.uuid)

    assert parent == chapter.uuid

    ctx.view
    |> element("#test-timeline-viewport")
    |> render_hook("timeline:chapter_edit", %{"id" => chapter.uuid})

    ctx.view |> element("button", "Delete") |> render_click()
    assert Chapters.list(ctx.library.uuid) == []
  end

  test "someone who may only look gets no dialog", ctx do
    _ = @viewer
    stranger = user_fixture("chapter-viewer-#{System.unique_integer([:positive])}@example.com")
    member_fixture(ctx.library, stranger, "viewer")

    {:ok, view, _html} =
      live_isolated(Phoenix.ConnTest.build_conn(), PhoenixKitPhotos.TestLive,
        session: %{
          "scope" => scope_for(stranger),
          "library" => {:library, ctx.library.uuid},
          "selectable" => true
        }
      )

    html =
      view
      |> element("#test-timeline-viewport")
      |> render_hook("timeline:bulk", %{"action" => "chapter", "ids" => [ctx.b.uuid]})

    refute html =~ "New chapter"
    refute html =~ ~s(data-bulk="chapter")
  end

  test "a chapter made elsewhere reaches the page", ctx do
    {:ok, _chapter} =
      Chapters.create(scope_for(ctx.user), ctx.library.uuid, %{
        "title" => "Moved",
        "starts_on" => "2026-07-20"
      })

    assert_push_event(
      ctx.view,
      "timeline:test-timeline:index",
      %{sections: [_, %{chapter: %{title: "Moved"}}]},
      2000
    )
  end
end
