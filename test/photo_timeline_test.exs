defmodule PhoenixKitPhotos.PhotoTimelineTest do
  use PhoenixKitPhotos.DataCase, async: false
  import Phoenix.LiveViewTest
  alias PhoenixKit.Modules.Storage

  @endpoint PhoenixKitPhotos.TestEndpoint

  setup do
    start_supervised!({Phoenix.PubSub, name: PhoenixKitPhotos.TestPubSub})
    start_supervised!(PhoenixKitPhotos.TestEndpoint)
    start_supervised!(PhoenixKit.PubSub.Manager)
    user = user_fixture("live-#{System.unique_integer([:positive])}@example.com")

    {:ok, view, _html} =
      live_isolated(Phoenix.ConnTest.build_conn(), PhoenixKitPhotos.TestLive,
        session: %{"scope" => scope_for(user), "library" => {:library, media_uuid()}}
      )

    %{view: view, user: user}
  end

  test "hook handshake and targeted window events reach the component", %{view: view, user: user} do
    file = file_fixture(user, %{})
    view |> element("#test-timeline-viewport") |> render_hook("timeline:ready", %{})
    assert_push_event(view, "timeline:test-timeline:index", %{revision: revision, total: 1})

    view
    |> element("#test-timeline-viewport")
    |> render_hook("timeline:need_window", %{window: "2018-07-14", revision: revision})

    assert_push_event(view, "timeline:test-timeline:window", %{
      items: [%{id: id}],
      revision: ^revision
    })

    assert id == file.uuid
  end

  test "storage PubSub refreshes the component without remounting", %{view: view, user: user} do
    file = file_fixture(user, %{})
    Storage.broadcast_file_processed(file.uuid)
    assert_push_event(view, "timeline:test-timeline:index", %{total: 1, revision: revision})
    assert revision > 1
    file |> Ecto.Changeset.change(trashed_at: DateTime.utc_now(:second)) |> TestRepo.update!()
    Storage.broadcast_files_trashed([file.uuid])
    assert_push_event(view, "timeline:test-timeline:index", %{total: 0})
    assert render(view) =~ "No photos yet."
  end

  test "a file event about another library does not touch this timeline", %{
    view: view,
    user: user
  } do
    view |> element("#test-timeline-viewport") |> render_hook("timeline:ready", %{})
    assert_push_event(view, "timeline:test-timeline:index", %{total: 0})

    other = library_fixture(user)
    elsewhere = file_fixture(user, %{library_uuid: other.uuid})
    Storage.broadcast_file_processed(elsewhere.uuid)
    refute_push_event(view, "timeline:test-timeline:index", _, 200)

    # and one about a file in this library does
    here = file_fixture(user, %{})
    Storage.broadcast_file_processed(here.uuid)
    assert_push_event(view, "timeline:test-timeline:index", %{total: 1})
  end

  test "a burst of events is one new index", %{view: view, user: user} do
    view |> element("#test-timeline-viewport") |> render_hook("timeline:ready", %{})
    assert_push_event(view, "timeline:test-timeline:index", %{total: 0, revision: first})
    file = file_fixture(user, %{})

    for _ <- 1..5, do: Storage.broadcast_file_thumbnail_updated(file.uuid)

    assert_push_event(view, "timeline:test-timeline:index", %{total: 1, revision: second})
    assert second == first + 1
    refute_push_event(view, "timeline:test-timeline:index", _, 200)
  end

  test "stale requests are ignored and jumping targets the timeline", %{view: view} do
    view
    |> element("#test-timeline-viewport")
    |> render_hook("timeline:need_window", %{window: "2018-07-14", revision: -1})

    refute_push_event(view, "timeline:test-timeline:window", _)
    view |> element("#test-timeline-viewport") |> render_hook("timeline:jump", %{id: "2018-07"})
    assert_push_event(view, "timeline:test-timeline:jump", %{id: "2018-07"})
  end

  test "slides come back to the component's own event, with the block they were asked for", %{
    view: view,
    user: user
  } do
    files =
      for n <- 1..3,
          do: file_fixture(user, %{taken_at: DateTime.add(~U[2018-07-14 08:00:00Z], n)})

    view |> element("#test-timeline-viewport") |> render_hook("timeline:ready", %{})
    assert_push_event(view, "timeline:test-timeline:index", %{revision: revision, total: 3})

    view
    |> element("#test-timeline-viewport")
    |> render_hook("timeline:slides", %{
      window: "2018-07-14",
      from: 1,
      count: 12,
      want: 800,
      revision: revision
    })

    assert_push_event(view, "timeline:test-timeline:slides", %{
      window: "2018-07-14",
      from: 1,
      count: 12,
      revision: ^revision,
      items: [%{id: second}, %{id: third}]
    })

    assert [second, third] == files |> Enum.drop(1) |> Enum.map(& &1.uuid)
  end

  test "stale or malformed slide requests are ignored; a bad day is an error the hook can retry",
       %{view: view, user: user} do
    file_fixture(user, %{})
    el = element(view, "#test-timeline-viewport")

    render_hook(el, "timeline:slides", %{
      window: "2018-07-14",
      from: 0,
      count: 12,
      want: 800,
      revision: -1
    })

    render_hook(el, "timeline:slides", %{
      window: "2018-07-14",
      from: "x",
      count: 12,
      want: 800,
      revision: 1
    })

    refute_push_event(view, "timeline:test-timeline:slides", _)

    render_hook(el, "timeline:ready", %{})
    assert_push_event(view, "timeline:test-timeline:index", %{revision: revision, total: 1})

    render_hook(el, "timeline:slides", %{
      window: "nonsense",
      from: 0,
      count: 12,
      want: 800,
      revision: revision
    })

    assert_push_event(view, "timeline:test-timeline:slides", %{items: [], error: true, from: 0})
  end

  test "the swipe viewer is off unless the host asks for it", %{view: view} do
    refute render(view) =~ ~s(data-pager="true")
    assert render(view) =~ ~s(data-pager="false")
  end

  test "the viewer engine is named by the host, and a bad name cannot break the page" do
    alias PhoenixKitPhotos.Components.PhotoTimeline
    assert PhotoTimeline.pager_setting(false) == "false"
    assert PhotoTimeline.pager_setting(nil) == "false"
    assert PhotoTimeline.pager_setting(true) == "true"
    assert PhotoTimeline.pager_setting(:snap) == "snap"
    assert PhotoTimeline.pager_setting("photoswipe") == "photoswipe"
    assert PhotoTimeline.pager_setting("Snap\" onclick=\"x") == "true"
    assert PhotoTimeline.pager_setting(String.duplicate("a", 33)) == "true"
    assert PhotoTimeline.pager_setting(42) == "true"
  end
end
