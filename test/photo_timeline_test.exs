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

    # The index sent with the page. Left in the mailbox, it is what a later
    # `assert_push_event(..., %{total: 0})` would match instead of the push it means.
    assert_push_event(view, "timeline:test-timeline:index", %{hello: false, revision: page})

    %{view: view, user: user, page_revision: page}
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

  # The page's own index is a revision behind once the hook says hello: an address may open the
  # viewer only in the answer.
  test "only the index answering the hook's hello says so", %{view: view, page_revision: page} do
    view |> element("#test-timeline-viewport") |> render_hook("timeline:ready", %{})
    assert_push_event(view, "timeline:test-timeline:index", %{hello: true, revision: hello})
    assert hello > page
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

defmodule PhoenixKitPhotos.PhotoTimelineStylesTest do
  use PhoenixKitPhotos.DataCase, async: false

  describe "Timeline.aspects/2" do
    setup do
      owner = user_fixture("aspects-#{System.unique_integer([:positive])}@example.com")
      %{owner: owner, library: library_fixture(owner)}
    end

    test "one byte per file of each month, in the timeline's order", %{
      owner: owner,
      library: library
    } do
      wide = file_fixture(owner, %{library_uuid: library.uuid, width: 8000, height: 1000})

      tall =
        file_fixture(owner, %{
          library_uuid: library.uuid,
          width: 1000,
          height: 8000,
          taken_at: ~U[2018-07-14 13:00:00Z]
        })

      square =
        file_fixture(owner, %{
          library_uuid: library.uuid,
          width: 500,
          height: 500,
          taken_on: ~D[2018-07-15],
          taken_at: ~U[2018-07-15 09:00:00Z]
        })

      _ = {wide, tall, square}
      {:ok, aspects} = Timeline.aspects({:library, library.uuid}, scope_for(owner))
      assert aspects == %{"2018-07" => <<255, 0, 128>>}
    end

    test "a ratio past the ends is held at the end", %{owner: owner, library: library} do
      file_fixture(owner, %{library_uuid: library.uuid, width: 30_000, height: 1000})
      {:ok, aspects} = Timeline.aspects({:library, library.uuid}, scope_for(owner))
      assert aspects == %{"2018-07" => <<255>>}
    end

    test "says nothing to someone who may not read the library", %{owner: owner, library: library} do
      file_fixture(owner, %{library_uuid: library.uuid})
      stranger = user_fixture("aspects-x-#{System.unique_integer([:positive])}@example.com")

      assert {:error, :unauthorized} =
               Timeline.aspects({:library, library.uuid}, scope_for(stranger))

      assert {:error, :unauthorized} = Timeline.aspects({:library, library.uuid}, nil)
    end
  end

  describe "Timeline.ids_between/3" do
    setup do
      owner = user_fixture("range-#{System.unique_integer([:positive])}@example.com")
      library = library_fixture(owner)

      files =
        for day <- 1..4 do
          date = Date.new!(2020, 3, day)

          file_fixture(owner, %{
            library_uuid: library.uuid,
            taken_on: date,
            taken_at: DateTime.new!(date, ~T[08:00:00]),
            file_type: if(day == 2, do: "video", else: "image")
          })
        end

      %{owner: owner, library: library, files: Enum.map(files, & &1.uuid)}
    end

    test "gives positions in the timeline's order, both ends included", ctx do
      scope = {:library, ctx.library.uuid}
      auth = scope_for(ctx.owner)
      assert {:ok, ids, false} = Timeline.ids_between(scope, auth, from: 1, to: 2, limit: 100)
      assert ids == Enum.slice(ctx.files, 1, 2)
    end

    test "stops at the limit and says so", ctx do
      scope = {:library, ctx.library.uuid}
      auth = scope_for(ctx.owner)
      assert {:ok, ids, true} = Timeline.ids_between(scope, auth, from: 0, to: 3, limit: 2)
      assert ids == Enum.take(ctx.files, 2)
    end

    test "takes one kind from the whole library", ctx do
      scope = {:library, ctx.library.uuid}
      auth = scope_for(ctx.owner)
      assert {:ok, [id], false} = Timeline.ids_between(scope, auth, kind: "video", limit: 100)
      assert id == Enum.at(ctx.files, 1)
    end

    test "gives nothing to a stranger", ctx do
      stranger = user_fixture("range-x-#{System.unique_integer([:positive])}@example.com")

      assert {:error, :unauthorized} =
               Timeline.ids_between({:library, ctx.library.uuid}, scope_for(stranger),
                 from: 0,
                 to: 3,
                 limit: 10
               )
    end
  end
end
