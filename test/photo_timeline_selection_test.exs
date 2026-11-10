defmodule PhoenixKitPhotos.PhotoTimelineSelectionTest do
  use PhoenixKitPhotos.DataCase, async: false
  import Phoenix.LiveViewTest

  alias PhoenixKit.Modules.Storage.File, as: StorageFile

  @endpoint PhoenixKitPhotos.TestEndpoint
  @viewer :viewer

  setup do
    _ = @viewer
    start_supervised!({Phoenix.PubSub, name: PhoenixKitPhotos.TestPubSub})
    start_supervised!(PhoenixKitPhotos.TestEndpoint)
    start_supervised!(PhoenixKit.PubSub.Manager)
    owner = user_fixture("sel-owner-#{System.unique_integer([:positive])}@example.com")
    library = library_fixture(owner)
    %{owner: owner, library: library}
  end

  defp open(ctx, user, session \\ %{}) do
    session =
      Map.merge(
        %{
          "scope" => scope_for(user),
          "library" => {:library, ctx.library.uuid},
          "selectable" => true,
          "photo_path" => "/anna/x/p/:code",
          "library_path" => "/anna/x"
        },
        session
      )

    {:ok, view, _html} =
      live_isolated(Phoenix.ConnTest.build_conn(), PhoenixKitPhotos.TestLive, session: session)

    view
  end

  defp hook(view, event, params) do
    view |> element("#test-timeline-viewport") |> render_hook(event, params)
  end

  # The mount pushed an index too: the one that counts is the last.
  defp revision(view) do
    hook(view, "timeline:ready", %{})
    latest_revision(nil)
  end

  defp latest_revision(last) do
    receive do
      {ref, {:push_event, "timeline:test-timeline:index", %{revision: revision}}}
      when is_reference(ref) ->
        latest_revision(revision)
    after
      30 -> last
    end
  end

  defp photo(ctx) do
    file_fixture(ctx.owner, %{library_uuid: ctx.library.uuid})
  end

  defp trashed?(file), do: not is_nil(TestRepo.get!(StorageFile, file.uuid).trashed_at)

  test "trash: asks, runs in the background, and can be undone", ctx do
    file = photo(ctx)
    view = open(ctx, ctx.owner)

    html = hook(view, "timeline:bulk", %{action: "trash", ids: [file.uuid]})
    assert html =~ "Move 1 item to the trash?"
    refute trashed?(file)

    view |> form("#test-timeline-bulk") |> render_submit()
    assert_push_event(view, "timeline:test-timeline:selection", %{clear: true}, 2000)
    assert trashed?(file)
    assert render(view) =~ "Moved 1 item to the trash"

    view |> element("button", "Undo") |> render_click()
    assert_push_event(view, "timeline:test-timeline:selection", %{clear: true}, 2000)
    refute trashed?(file)
  end

  test "a viewer has no Trash, and a forged event gets nowhere", ctx do
    file = photo(ctx)
    viewer = user_fixture("sel-viewer-#{System.unique_integer([:positive])}@example.com")
    member_fixture(ctx.library, viewer, "viewer")
    view = open(ctx, viewer)
    refute render(view) =~ ~s(data-bulk="trash")
    assert render(view) =~ ~s(data-bulk="links")

    html = hook(view, "timeline:bulk", %{action: "trash", ids: [file.uuid]})
    refute html =~ "to the trash?"
    refute trashed?(file)
  end

  test "a contributor's dialog says what is not theirs, and it stays", ctx do
    mine_owner = user_fixture("sel-c-#{System.unique_integer([:positive])}@example.com")
    member_fixture(ctx.library, mine_owner, "contributor")
    theirs = photo(ctx)
    mine = file_fixture(mine_owner, %{library_uuid: ctx.library.uuid})
    view = open(ctx, mine_owner)

    html = hook(view, "timeline:bulk", %{action: "trash", ids: [mine.uuid, theirs.uuid]})
    assert html =~ "Move 1 item to the trash?"
    assert html =~ "not yours to change"

    view |> form("#test-timeline-bulk") |> render_submit()
    assert_push_event(view, "timeline:test-timeline:selection", %{clear: true}, 2000)
    assert trashed?(mine)
    refute trashed?(theirs)
  end

  test "rights lost after the dialog opened count: it is planned again on yes", ctx do
    helper = user_fixture("sel-h-#{System.unique_integer([:positive])}@example.com")
    member = member_fixture(ctx.library, helper, "manager")
    file = photo(ctx)
    view = open(ctx, helper)
    assert hook(view, "timeline:bulk", %{action: "trash", ids: [file.uuid]}) =~ "to the trash?"

    TestRepo.delete!(member)
    view |> form("#test-timeline-bulk") |> render_submit()
    assert_push_event(view, "timeline:test-timeline:selection", %{clear: true}, 2000)
    refute trashed?(file)
  end

  test "an unknown action and a list that is not a list do nothing", ctx do
    file = photo(ctx)
    view = open(ctx, ctx.owner)
    refute hook(view, "timeline:bulk", %{action: "delete", ids: [file.uuid]}) =~ "modal-open"
    refute hook(view, "timeline:bulk", %{action: "trash", ids: file.uuid}) =~ "modal-open"
    refute hook(view, "timeline:bulk_run", %{}) =~ "modal-open"
    refute trashed?(file)
  end

  test "a forged download event does not bring the page down", ctx do
    file = photo(ctx)
    view = open(ctx, ctx.owner, %{"download_path" => "/photos/download"})
    refute hook(view, "timeline:bulk", %{action: "download", ids: [file.uuid]}) =~ "modal-open"
    assert render(view) =~ "test-timeline"
  end

  test "a timeline that is not selectable answers none of it", ctx do
    file = photo(ctx)
    view = open(ctx, ctx.owner, %{"selectable" => false})
    refute render(view) =~ "data-selection-bar"
    refute hook(view, "timeline:bulk", %{action: "trash", ids: [file.uuid]}) =~ "modal-open"
    revision = revision(view)
    hook(view, "timeline:range", %{from: 0, to: 0, mode: "add", revision: revision})
    refute_push_event(view, "timeline:test-timeline:range", _, 50)
  end

  test "a range is resolved for the page, and a stale one is not", ctx do
    file = photo(ctx)
    view = open(ctx, ctx.owner)
    revision = revision(view)
    hook(view, "timeline:range", %{from: 0, to: 5, mode: "toggle", revision: revision})

    assert_push_event(view, "timeline:test-timeline:range", %{
      ids: ids,
      mode: "toggle",
      capped: false
    })

    assert ids == [file.uuid]

    hook(view, "timeline:range", %{from: 0, to: 5, mode: "add", revision: revision + 7})
    refute_push_event(view, "timeline:test-timeline:range", _, 50)

    hook(view, "timeline:range", %{from: "x", to: nil, mode: "<nope>", revision: revision})
    assert_push_event(view, "timeline:test-timeline:range", %{mode: "add"})

    # Past what Postgres takes as an offset: ignored, not a crashed page.
    huge = 100_000_000_000_000_000_000
    hook(view, "timeline:range", %{from: huge, to: huge + 5, mode: "add", revision: revision})
    assert_push_event(view, "timeline:test-timeline:range", %{mode: "add"})

    # Events without the keys they need are dropped.
    for name <- ~w(timeline:range timeline:aspects timeline:need_window),
        do: hook(view, name, %{})

    assert render(view) =~ "test-timeline-viewport"
  end

  test "copy links gives the page the addresses of the files", ctx do
    file = photo(ctx)
    view = open(ctx, ctx.owner)
    hook(view, "timeline:bulk", %{action: "links", ids: [file.uuid]})
    assert_push_event(view, "timeline:test-timeline:links", %{paths: [path]})
    assert path == "/anna/x/p/#{file.short_code}"
  end

  test "tags need something to do before the button works", ctx do
    file = photo(ctx)
    view = open(ctx, ctx.owner)
    hook(view, "timeline:bulk", %{action: "tag", ids: [file.uuid]})
    assert view |> element("#test-timeline-bulk button[type=submit][disabled]") |> has_element?()

    view |> form("#test-timeline-bulk", %{add: "summer"}) |> render_change()
    refute view |> element("#test-timeline-bulk button[type=submit][disabled]") |> has_element?()

    view |> form("#test-timeline-bulk", %{add: "summer"}) |> render_submit()
    assert_push_event(view, "timeline:test-timeline:selection", %{clear: true}, 2000)
    assert TestRepo.get!(StorageFile, file.uuid).metadata["tags"] == ["summer"]
  end
end
