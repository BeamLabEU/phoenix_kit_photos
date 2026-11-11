defmodule PhoenixKitPhotos.PhotoUploaderTest do
  @moduledoc """
  The uploader component through LiveView's own upload test helpers: who sees it,
  private (starts by itself) and public (waits, with a warning), a real file stored in
  the library, the same bytes again, refusals, and what it tells the page.
  """
  use PhoenixKitPhotos.DataCase, async: false

  import Phoenix.LiveViewTest

  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Modules.Storage.Bucket

  @endpoint PhoenixKitPhotos.TestEndpoint
  @buckets_cache :phoenix_kit_buckets_cache
  @png Base.decode64!(
         "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
       )

  setup do
    start_supervised!({Phoenix.PubSub, name: PhoenixKitPhotos.TestPubSub})
    start_supervised!(PhoenixKitPhotos.TestEndpoint)
    start_supervised!(PhoenixKit.PubSub.Manager)

    :persistent_term.erase(@buckets_cache)
    n = System.unique_integer([:positive])
    root = Path.join(System.tmp_dir!(), "pk_photos_uploader_#{n}")
    TestRepo.update_all(Bucket, set: [enabled: false])

    {:ok, _} =
      Storage.create_bucket(%{
        name: "uploader-#{n}",
        provider: "local",
        endpoint: root,
        enabled: true,
        priority: 0
      })

    on_exit(fn ->
      :persistent_term.erase(@buckets_cache)
      File.rm_rf(root)
    end)

    owner = user_fixture("owner-#{n}@example.com")
    %{n: n, owner: owner, library: library_fixture(owner)}
  end

  defp mount!(scope, library, extra \\ %{}) do
    {:ok, view, html} =
      live_isolated(Phoenix.ConnTest.build_conn(), PhoenixKitPhotos.UploadLive,
        session: Map.merge(%{"scope" => scope, "library" => library.uuid}, extra)
      )

    {view, html}
  end

  defp upload(view, name, content \\ @png, type \\ "image/png") do
    view
    |> file_input("#test-uploader-form", :photos, [%{name: name, content: content, type: type}])
  end

  defp make_public(library) do
    library |> Ecto.Changeset.change(visibility: "site") |> TestRepo.update!()
  end

  describe "who sees it" do
    test "the owner sees the add button; a viewer and a stranger see nothing", ctx do
      {_view, html} = mount!(scope_for(ctx.owner), ctx.library)
      assert html =~ "Add photos"
      assert html =~ ~s(phx-hook="PhotoUploader")

      viewer = user_fixture("viewer-#{ctx.n}@example.com")
      member_fixture(ctx.library, viewer, "viewer")
      {_view, html} = mount!(scope_for(viewer), ctx.library)
      refute html =~ "Add photos"
      refute html =~ "PhotoUploader"

      stranger = user_fixture("stranger-#{ctx.n}@example.com")
      {_view, html} = mount!(scope_for(stranger), ctx.library)
      refute html =~ "Add photos"
    end

    test "a contributor sees it", ctx do
      contributor = user_fixture("contrib-#{ctx.n}@example.com")
      member_fixture(ctx.library, contributor, "contributor")

      {_view, html} = mount!(scope_for(contributor), ctx.library)
      assert html =~ "Add photos"
    end

    test "the panel opens and closes, and names the library", ctx do
      {view, _html} = mount!(scope_for(ctx.owner), ctx.library)

      html = view |> element("button[aria-label='Add photos']") |> render_click()
      assert html =~ "Choose files"
      assert html =~ ctx.library.name
      assert html =~ "anywhere on the page"

      html = view |> element("button[aria-label='Close']") |> render_click()
      refute html =~ "Choose files"
    end
  end

  describe "a private library" do
    test "a component update preserves an upload already in progress", ctx do
      {view, _} = mount!(scope_for(ctx.owner), ctx.library)
      view |> element("button[aria-label='Add photos']") |> render_click()
      input = upload(view, "still-uploading.png")
      render_upload(input, "still-uploading.png", 50)

      Phoenix.LiveView.send_update(view.pid, PhoenixKitPhotos.Components.PhotoUploader,
        id: "test-uploader",
        library_uuid: ctx.library.uuid,
        auth: scope_for(ctx.owner)
      )

      view |> element("#test-uploader") |> render_hook("ready", %{})
      assert_reply(view, %{idle: false, in_flight: 1})
      assert render_upload(input, "still-uploading.png", 50) =~ "1 added"
      assert [%{original_file_name: "still-uploading.png"}] = Storage.list_files()
    end

    test "a chosen file starts at once and is stored in the library", ctx do
      {view, _} = mount!(scope_for(ctx.owner), ctx.library)
      view |> element("button[aria-label='Add photos']") |> render_click()

      input = upload(view, "holiday.png")
      assert render_upload(input, "holiday.png") =~ "1 added"

      assert [file] = Storage.list_files()
      assert file.original_file_name == "holiday.png"
      assert file.library_uuid == ctx.library.uuid
      assert file.user_uuid == ctx.owner.uuid
    end

    test "a new file's tile says its previews are being made until it can be shown", ctx do
      {view, _} = mount!(scope_for(ctx.owner), ctx.library)
      view |> element("button[aria-label='Add photos']") |> render_click()

      html = view |> upload("holiday.png") |> render_upload("holiday.png")
      # In the library, and said so; the timeline cannot show it yet, and that is said too.
      assert html =~ "1 added"
      assert html =~ "Making previews…"
      assert has_element?(view, "#test-uploader-tiles li[data-state=preparing]", "holiday.png")
      # The button counts it while the panel is closed.
      html = view |> element("button[aria-label='Close']") |> render_click()
      assert html =~ "loading-spinner"

      assert [file] = Storage.list_files()

      # Another file's news changes nothing; this file's takes the tile away.
      Phoenix.LiveView.send_update(view.pid, PhoenixKitPhotos.Components.PhotoUploader,
        id: "test-uploader",
        files_processed: [Ecto.UUID.generate()]
      )

      view |> element("button[aria-label='Add photos']") |> render_click()
      assert render(view) =~ "Making previews…"

      Phoenix.LiveView.send_update(view.pid, PhoenixKitPhotos.Components.PhotoUploader,
        id: "test-uploader",
        files_processed: [file.uuid]
      )

      html = render(view)
      refute html =~ "Making previews…"
      assert html =~ "1 added"
      # The tile says so for a moment (none, in this test), then goes with the next check.
      assert has_element?(view, "#test-uploader-tiles li[data-state=added]", "holiday.png")
      Application.put_env(:phoenix_kit_photos, :added_tile_ms, 0)
      on_exit(fn -> Application.delete_env(:phoenix_kit_photos, :added_tile_ms) end)

      Phoenix.LiveView.send_update(view.pid, PhoenixKitPhotos.Components.PhotoUploader,
        id: "test-uploader",
        preparing_check: true
      )

      refute has_element?(view, "#test-uploader-tiles")
    end

    test "a missed message is made up for by asking the database", ctx do
      {view, _} = mount!(scope_for(ctx.owner), ctx.library)
      view |> element("button[aria-label='Add photos']") |> render_click()
      assert view |> upload("holiday.png") |> render_upload("holiday.png") =~ "Making previews…"
      assert [file] = Storage.list_files()

      # Still being processed: the tile stays.
      Phoenix.LiveView.send_update(view.pid, PhoenixKitPhotos.Components.PhotoUploader,
        id: "test-uploader",
        preparing_check: true
      )

      assert render(view) =~ "Making previews…"

      # Processing gave up on it: nothing more to wait for.
      file |> Ecto.Changeset.change(status: "failed") |> TestRepo.update!()

      Phoenix.LiveView.send_update(view.pid, PhoenixKitPhotos.Components.PhotoUploader,
        id: "test-uploader",
        preparing_check: true
      )

      refute render(view) =~ "Making previews…"
    end

    test "the same picture again is already there, not a second file", ctx do
      {view, _} = mount!(scope_for(ctx.owner), ctx.library)
      view |> element("button[aria-label='Add photos']") |> render_click()

      view |> upload("a.png") |> render_upload("a.png")
      html = view |> upload("copy.png") |> render_upload("copy.png")

      assert html =~ "1 already in this library"
      assert length(Storage.list_files()) == 1
    end

    test "something that is not a photo or video is refused before it is sent", ctx do
      {view, _} = mount!(scope_for(ctx.owner), ctx.library)
      view |> element("button[aria-label='Add photos']") |> render_click()

      assert {:error, [[_ref, :not_accepted]]} =
               view
               |> upload("page.html", "<script></script>", "text/html")
               |> render_upload("page.html")

      assert {:error, [[_ref, :not_accepted]]} =
               view
               |> upload("notes.pdf", "%PDF", "application/pdf")
               |> render_upload("notes.pdf")

      assert Storage.list_files() == []
    end

    test "a refused file is reported and cleared, so it holds no place and blocks no batch",
         ctx do
      {view, _} = mount!(scope_for(ctx.owner), ctx.library)
      view |> element("button[aria-label='Add photos']") |> render_click()

      input = upload(view, "page.html", "<script></script>", "text/html")
      assert {:error, [[_ref, :not_accepted]]} = render_upload(input, "page.html")

      # The form's change event a browser sends as files are chosen (the test client's
      # upload helper goes straight to the preflight and skips it).
      html = view |> element("#test-uploader") |> render_hook("validate", %{})
      # Told once, in the summary, and gone from the queue (no progress bar, no cancel).
      assert html =~ "page.html"
      assert html =~ "not supported"
      assert html =~ "1 failed"
      refute html =~ ~s(phx-click="cancel")

      # And the hook, which asks before it sends the next batch, is told nothing is left
      # in flight.
      view |> element("#test-uploader") |> render_hook("ready", %{})
      assert_reply(view, %{idle: true, in_flight: 0})
    end

    test "ready says how many are in flight, so the hook can keep its window full", ctx do
      library = make_public(ctx.library)
      {view, _} = mount!(scope_for(ctx.owner), library)
      view |> element("button[aria-label='Add photos']") |> render_click()

      view |> element("#test-uploader") |> render_hook("ready", %{})
      assert_reply(view, %{idle: true, in_flight: 0})

      # Chosen in a public library, it waits for Upload: the next batch must wait too.
      input = upload(view, "w.png")
      render_upload(input, "w.png", 0)
      view |> element("#test-uploader") |> render_hook("ready", %{})
      assert_reply(view, %{idle: false, in_flight: 1})

      view |> form("#test-uploader-form") |> render_submit()
      render_upload(input, "w.png")
      view |> element("#test-uploader") |> render_hook("ready", %{})
      assert_reply(view, %{idle: true, in_flight: 0})
    end

    test "cancel all drops every entry in flight or waiting, and stores nothing", ctx do
      library = make_public(ctx.library)
      {view, _} = mount!(scope_for(ctx.owner), library)
      view |> element("button[aria-label='Add photos']") |> render_click()

      input = upload(view, "w.png")
      html = render_upload(input, "w.png", 0)
      assert html =~ "w.png"
      assert html =~ "Cancel all"

      view |> element("button[data-cancel-all]") |> render_click()
      html = render(view)
      refute html =~ "w.png"
      refute html =~ "Cancel all"

      view |> element("#test-uploader") |> render_hook("ready", %{})
      assert_reply(view, %{idle: true, in_flight: 0})
      assert Storage.list_files() == []
    end

    test "cancel all works while a file is mid-upload, and stores nothing", ctx do
      {view, _} = mount!(scope_for(ctx.owner), ctx.library)
      view |> element("button[aria-label='Add photos']") |> render_click()

      input = upload(view, "mid.png")
      html = render_upload(input, "mid.png", 50)
      assert html =~ "mid.png"
      assert html =~ "Cancel all"

      view |> element("button[data-cancel-all]") |> render_click()
      html = render(view)
      refute html =~ "mid.png"

      view |> element("#test-uploader") |> render_hook("ready", %{})
      assert_reply(view, %{idle: true, in_flight: 0})
      assert Storage.list_files() == []
    end

    test "the panel offers the concurrency control with the server's default", ctx do
      {_view, html} = mount!(scope_for(ctx.owner), ctx.library)
      assert html =~ ~s(data-concurrency="4")
      assert html =~ ~s(data-concurrency-max="8")

      {view, _} = mount!(scope_for(ctx.owner), ctx.library)
      html = view |> element("button[aria-label='Add photos']") |> render_click()
      assert html =~ "Uploads at once"
      assert html =~ ~s(data-concurrency-select)
      assert html =~ ~s(value="1")
      assert html =~ ~s(value="8")
      assert html =~ "selected"
    end

    test "a file over the site's limit says so", ctx do
      {:ok, _} = PhoenixKit.Settings.update_setting("storage_max_upload_size_mb", "1")
      {view, _} = mount!(scope_for(ctx.owner), ctx.library)
      view |> element("button[aria-label='Add photos']") |> render_click()

      big = :binary.copy("x", 2 * 1_048_576)
      input = upload(view, "big.png", big)

      assert {:error, [[_ref, :too_large]]} = render_upload(input, "big.png")
      assert Storage.list_files() == []
    end

    test "a heic the browser gave no type for is taken", ctx do
      {view, _} = mount!(scope_for(ctx.owner), ctx.library)
      view |> element("button[aria-label='Add photos']") |> render_click()

      # Not a real HEIC (no encoder here), so the pipeline may refuse its bytes; what is
      # tested is that the uploader does not turn it away for its name and missing type.
      input = upload(view, "IMG_0001.HEIC", "not-really", "")
      assert is_binary(render_upload(input, "IMG_0001.HEIC"))
    end
  end

  describe "a public library" do
    test "visibility updates reconfigure the gate in both directions", ctx do
      {view, _} = mount!(scope_for(ctx.owner), ctx.library)
      assert render(view) =~ ~s(data-auto="true")

      for {visibility, auto} <- [{"site", "false"}, {"private", "true"}] do
        ctx.library
        |> TestRepo.reload!()
        |> Ecto.Changeset.change(visibility: visibility)
        |> TestRepo.update!()

        Phoenix.LiveView.send_update(view.pid, PhoenixKitPhotos.Components.PhotoUploader,
          id: "test-uploader",
          library_uuid: ctx.library.uuid,
          auth: scope_for(ctx.owner)
        )

        assert render(view) =~ ~s(data-auto="#{auto}")
      end
    end

    test "warns, waits for Upload, then stores", ctx do
      library = make_public(ctx.library)
      {view, _} = mount!(scope_for(ctx.owner), library)

      html = view |> element("button[aria-label='Add photos']") |> render_click()
      assert html =~ "This library is public"

      input = upload(view, "p.png")
      html = render_upload(input, "p.png", 0)
      # Chosen, but nothing went: it waits for the button, with no progress bar.
      assert html =~ "waiting"
      refute html =~ "<progress"
      assert html =~ "Upload 1 file"
      assert Storage.list_files() == []

      # The button counts what is queued in the hook too, not just registered entries.
      html =
        view
        |> element("#test-uploader")
        |> render_hook("waiting", %{"count" => 7, "names" => ["a.jpg", "b.jpg"]})

      assert html =~ "Upload 8 files"
      assert html =~ "a.jpg"
      assert html =~ "5 more files are waiting"

      view |> form("#test-uploader-form") |> render_submit()
      # Once Upload was pressed the button is gone while it runs; Cancel all stays.
      html = render(view)
      refute html =~ "Upload 1 file"
      assert html =~ "Cancel all"

      assert render_upload(input, "p.png") =~ "1 added"
      assert [%{library_uuid: uuid}] = Storage.list_files()
      assert uuid == library.uuid
    end

    test "a private library does not show the warning", ctx do
      {view, _} = mount!(scope_for(ctx.owner), ctx.library)
      html = view |> element("button[aria-label='Add photos']") |> render_click()
      refute html =~ "This library is public"
      refute html =~ "Upload 1 file"
    end
  end

  describe "telling the page" do
    test "on_stored sends each result to the parent, and only then", ctx do
      {view, _} = mount!(scope_for(ctx.owner), ctx.library, %{"on_stored" => :stored})
      view |> element("button[aria-label='Add photos']") |> render_click()
      view |> upload("n.png") |> render_upload("n.png")

      assert [{"test-uploader", {:added, %{original_file_name: "n.png"}}}] =
               GenServer.call(view.pid, :stored)

      {quiet, _} = mount!(scope_for(ctx.owner), ctx.library)
      quiet |> element("button[aria-label='Add photos']") |> render_click()
      quiet |> upload("q.png") |> render_upload("q.png")
      assert GenServer.call(quiet.pid, :stored) == []
    end
  end

  describe "dropped files (from the hook)" do
    test "a drop opens the panel and says what was left out of a folder", ctx do
      {view, _} = mount!(scope_for(ctx.owner), ctx.library)

      html =
        view
        |> element("#test-uploader")
        |> render_hook("dropped", %{"files" => 10, "skipped" => 3, "truncated" => false})

      assert html =~ "Choose files"
      assert html =~ "3 files in the folder were left out"
    end

    test "a folder the browser would not open is said so, not silently ignored", ctx do
      {view, _} = mount!(scope_for(ctx.owner), ctx.library)

      html =
        view
        |> element("#test-uploader")
        |> render_hook("dropped", %{
          "files" => 0,
          "skipped" => 0,
          "unreadable" => 1,
          "truncated" => false
        })

      assert html =~ "1 folder could not be read"
      assert html =~ "Choose files"
    end

    test "the hook's counts are only trusted as small numbers", ctx do
      {view, _} = mount!(scope_for(ctx.owner), ctx.library)

      html =
        view
        |> element("#test-uploader")
        |> render_hook("dropped", %{"files" => "x", "skipped" => -5, "truncated" => "yes"})

      refute html =~ "left out"
      html = view |> element("#test-uploader") |> render_hook("waiting", %{"count" => "many"})
      refute html =~ "more file"
    end

    test "waiting lists the queued file names, and counts the rest", ctx do
      {view, _} = mount!(scope_for(ctx.owner), ctx.library)
      view |> element("button[aria-label='Add photos']") |> render_click()

      html =
        view
        |> element("#test-uploader")
        |> render_hook("waiting", %{"count" => 120, "names" => ["a.jpg", "b.jpg"]})

      # The whole selection is listed as waiting, not just what is in flight.
      assert html =~ "a.jpg"
      assert html =~ "b.jpg"
      assert html =~ "118 more files are waiting"

      html =
        view
        |> element("#test-uploader")
        |> render_hook("waiting", %{"count" => 0, "names" => []})

      refute html =~ "a.jpg"
      refute html =~ "more file"
    end
  end
end
