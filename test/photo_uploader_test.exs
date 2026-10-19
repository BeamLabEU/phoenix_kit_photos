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

    test "the same picture again is already there, not a second file", ctx do
      {view, _} = mount!(scope_for(ctx.owner), ctx.library)
      view |> element("button[aria-label='Add photos']") |> render_click()

      view |> upload("a.png") |> render_upload("a.png")
      html = view |> upload("copy.png") |> render_upload("copy.png")

      assert html =~ "1 already there"
      assert length(Storage.list_files()) == 1
    end

    test "something that is not a photo or video is refused before it is sent", ctx do
      {view, _} = mount!(scope_for(ctx.owner), ctx.library)
      view |> element("button[aria-label='Add photos']") |> render_click()

      assert {:error, [[_ref, :not_accepted]]} =
               view
               |> upload("script.svg", "<svg/>", "image/svg+xml")
               |> render_upload("script.svg")

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

      input = upload(view, "script.svg", "<svg/>", "image/svg+xml")
      assert {:error, [[_ref, :not_accepted]]} = render_upload(input, "script.svg")

      # The form's change event a browser sends as files are chosen (the test client's
      # upload helper goes straight to the preflight and skips it).
      html = view |> element("#test-uploader") |> render_hook("validate", %{})
      # Told once, in the summary, and gone from the queue (no progress bar, no cancel).
      assert html =~ "script.svg"
      assert html =~ "not supported"
      assert html =~ "1 failed"
      refute html =~ ~s(phx-click="cancel")

      # And the hook, which asks before it sends the next batch, is told nothing is left
      # in flight.
      view |> element("#test-uploader") |> render_hook("ready", %{})
      assert_reply(view, %{idle: true})
    end

    test "ready is not idle while a file is uploading or waiting for a click", ctx do
      library = make_public(ctx.library)
      {view, _} = mount!(scope_for(ctx.owner), library)
      view |> element("button[aria-label='Add photos']") |> render_click()

      view |> element("#test-uploader") |> render_hook("ready", %{})
      assert_reply(view, %{idle: true})

      # Chosen in a public library, it waits for Upload: the next batch must wait too.
      input = upload(view, "w.png")
      render_upload(input, "w.png", 0)
      view |> element("#test-uploader") |> render_hook("ready", %{})
      assert_reply(view, %{idle: false})

      view |> form("#test-uploader-form") |> render_submit()
      render_upload(input, "w.png")
      view |> element("#test-uploader") |> render_hook("ready", %{})
      assert_reply(view, %{idle: true})
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
    test "warns, waits for Upload, then stores", ctx do
      library = make_public(ctx.library)
      {view, _} = mount!(scope_for(ctx.owner), library)

      html = view |> element("button[aria-label='Add photos']") |> render_click()
      assert html =~ "This library is public"

      input = upload(view, "p.png")
      html = render_upload(input, "p.png", 0)
      # Chosen, but nothing went: it waits for the button.
      assert html =~ "waiting"
      assert html =~ "Upload 1 file"
      assert Storage.list_files() == []

      view |> form("#test-uploader-form") |> render_submit()
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
  end
end
