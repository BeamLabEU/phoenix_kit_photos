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

  test "stale requests are ignored and jumping targets the timeline", %{view: view} do
    view
    |> element("#test-timeline-viewport")
    |> render_hook("timeline:need_window", %{window: "2018-07-14", revision: -1})

    refute_push_event(view, "timeline:test-timeline:window", _)
    view |> element("#test-timeline-viewport") |> render_hook("timeline:jump", %{id: "2018-07"})
    assert_push_event(view, "timeline:test-timeline:jump", %{id: "2018-07"})
  end
end
