defmodule PhoenixKitPhotos.BackgroundUploadTest do
  @moduledoc """
  Saving in the background: the uploader moves a finished file out of LiveView's temp
  file and `StoreUploadJob` stores it, retrying while storage is down, and the panel
  says *Saving…* until it hears back. The regression it guards: a store that kept the
  page waiting made LiveView's client reload the page and lose the files in flight
  (Fotki's `dev_docs/plans/2026-11-10-resilient-photo-uploads.md`).
  """
  use PhoenixKitPhotos.DataCase, async: false

  import Ecto.Query
  import Phoenix.LiveViewTest

  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Modules.Storage.Bucket
  alias PhoenixKitPhotos.{StagingSweepJob, StoreUploadJob, UploadStaging}

  @endpoint PhoenixKitPhotos.TestEndpoint
  @buckets_cache :phoenix_kit_buckets_cache
  @png Base.decode64!(
         "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
       )

  setup do
    start_supervised!({Phoenix.PubSub, name: PhoenixKitPhotos.TestPubSub})
    start_supervised!(PhoenixKitPhotos.TestEndpoint)
    start_supervised!(PhoenixKit.PubSub.Manager)
    start_supervised!({Oban, name: Oban, repo: TestRepo, testing: :manual})

    n = System.unique_integer([:positive])
    staging = Path.join(System.tmp_dir!(), "pk_photos_staging_#{n}")
    Application.put_env(:phoenix_kit_photos, :staging_dir, staging)
    Application.put_env(:phoenix_kit_photos, :store_in_background, true)

    :persistent_term.erase(@buckets_cache)
    root = Path.join(System.tmp_dir!(), "pk_photos_bg_#{n}")
    TestRepo.update_all(Bucket, set: [enabled: false])

    {:ok, bucket} =
      Storage.create_bucket(%{
        name: "bg-#{n}",
        provider: "local",
        endpoint: root,
        enabled: true,
        priority: 0
      })

    on_exit(fn ->
      Application.delete_env(:phoenix_kit_photos, :staging_dir)
      Application.delete_env(:phoenix_kit_photos, :store_in_background)
      :persistent_term.erase(@buckets_cache)
      File.rm_rf(root)
      File.rm_rf(staging)
    end)

    owner = confirmed(user_fixture("bg-owner-#{n}@example.com"))

    %{
      owner: owner,
      scope: scope_for(owner),
      library: library_fixture(owner),
      bucket: bucket,
      staging: staging
    }
  end

  defp confirmed(user) do
    user
    |> Ecto.Changeset.change(confirmed_at: DateTime.utc_now(:second))
    |> TestRepo.update!()
  end

  defp mount!(live, scope, library) do
    {:ok, view, _html} =
      live_isolated(Phoenix.ConnTest.build_conn(), live,
        session: %{"scope" => scope, "library" => library.uuid}
      )

    view |> element("button[aria-label='Add photos']") |> render_click()
    view
  end

  defp upload(view, form, name, content \\ @png) do
    file_input(view, form, :photos, [%{name: name, content: content, type: "image/png"}])
  end

  defp staged_files(dir) do
    case File.ls(dir) do
      {:ok, names} -> names
      {:error, _} -> []
    end
  end

  defp library_files(library) do
    TestRepo.all(
      from f in Storage.File, where: f.library_uuid == ^library.uuid and f.status != "trashed"
    )
  end

  defp buckets(enabled?, bucket) do
    TestRepo.update_all(from(b in Bucket, where: b.uuid == ^bucket.uuid),
      set: [enabled: enabled?]
    )

    :persistent_term.erase(@buckets_cache)
  end

  describe "the uploader on a page that can hear back" do
    test "hands a finished file over: Saving… at once, added when the job has stored it", ctx do
      view = mount!(PhoenixKitPhotos.BackgroundUploadLive, ctx.scope, ctx.library)
      html = view |> upload("#bg-uploader-form", "holiday.png") |> render_upload("holiday.png")

      # Nothing is stored while the page waits; the file left LiveView's temp file.
      assert html =~ "Saving…"
      refute html =~ "1 added"
      assert library_files(ctx.library) == []
      assert [_staged] = staged_files(ctx.staging)

      assert %{success: 1} = Oban.drain_queue(queue: :photo_uploads)

      html = render(view)
      assert html =~ "1 added"
      refute html =~ "Saving…"
      assert [%{original_file_name: "holiday.png"}] = library_files(ctx.library)
      assert staged_files(ctx.staging) == []
      # on_stored keeps its shape: the parent hears once the file is stored.
      assert [{"bg-uploader", {:added, _file}}] = GenServer.call(view.pid, :stored)
    end

    test "a stored file's tile waits for its previews, and the page's own news ends it", ctx do
      view = mount!(PhoenixKitPhotos.BackgroundUploadLive, ctx.scope, ctx.library)
      view |> upload("#bg-uploader-form", "holiday.png") |> render_upload("holiday.png")
      assert has_element?(view, "#bg-uploader-tiles li[data-state=saving]", "holiday.png")

      assert %{success: 1} = Oban.drain_queue(queue: :photo_uploads)
      assert has_element?(view, "#bg-uploader-tiles li[data-state=preparing]", "holiday.png")
      assert [file] = library_files(ctx.library)

      # What core says when a file's sizes are ready, relayed by `LiveUpdates`.
      Storage.broadcast_file_processed(file.uuid)
      # The page hears it, then tells the component: two messages to get through.
      render(view)
      refute render(view) =~ "Making previews…"
      assert has_element?(view, "#bg-uploader-tiles li[data-state=added]", "holiday.png")
    end

    test "storage being down is retried with the file kept, and the panel says so", ctx do
      view = mount!(PhoenixKitPhotos.BackgroundUploadLive, ctx.scope, ctx.library)
      view |> upload("#bg-uploader-form", "later.png") |> render_upload("later.png")

      buckets(false, ctx.bucket)
      assert %{failure: 1} = Oban.drain_queue(queue: :photo_uploads)
      assert render(view) =~ "trying again"
      assert [_staged] = staged_files(ctx.staging)

      buckets(true, ctx.bucket)
      # The retry, and the sweep the staging scheduled an hour out.
      assert %{success: 2, failure: 0} =
               Oban.drain_queue(queue: :photo_uploads, with_scheduled: true)

      assert render(view) =~ "1 added"
      assert [_file] = library_files(ctx.library)
      assert staged_files(ctx.staging) == []
    end

    test "a file it does not take is refused at once, with no job", ctx do
      view = mount!(PhoenixKitPhotos.BackgroundUploadLive, ctx.scope, ctx.library)

      html =
        view
        |> file_input("#bg-uploader-form", :photos, [
          %{name: "fake.svg", content: "not an svg", type: "image/svg+xml"}
        ])
        |> render_upload("fake.svg")

      assert html =~ "1 failed"
      assert %{success: 0, failure: 0} = Oban.drain_queue(queue: :photo_uploads)
      assert staged_files(ctx.staging) == []
    end

    test "the hook is told the window is fuller once many files are saving", ctx do
      view = mount!(PhoenixKitPhotos.BackgroundUploadLive, ctx.scope, ctx.library)

      for i <- 1..10 do
        view
        |> upload("#bg-uploader-form", "f#{i}.png", @png <> <<i>>)
        |> render_upload("f#{i}.png")
      end

      # Ten saving, eight of them free: two hold a place.
      view |> element("#bg-uploader") |> render_hook("ready", %{})
      assert_reply(view, %{idle: false, in_flight: 2})
    end
  end

  test "a page without LiveUpdates stores inline, as before", ctx do
    {:ok, view, _html} =
      live_isolated(Phoenix.ConnTest.build_conn(), PhoenixKitPhotos.UploadLive,
        session: %{"scope" => ctx.scope, "library" => ctx.library.uuid}
      )

    view |> element("button[aria-label='Add photos']") |> render_click()
    html = view |> upload("#test-uploader-form", "inline.png") |> render_upload("inline.png")
    assert html =~ "1 added"
    assert staged_files(ctx.staging) == []
  end

  defp stage!(content \\ @png) do
    tmp = Path.join(System.tmp_dir!(), "pk_photos_src_#{System.unique_integer([:positive])}")
    File.write!(tmp, content)
    {:ok, staged} = UploadStaging.stage(tmp)
    staged
  end

  describe "StoreUploadJob" do
    defp args(staged, ctx, extra \\ %{}) do
      Map.merge(
        %{
          "staged" => staged,
          "name" => "job.png",
          "type" => "image/png",
          "user_uuid" => ctx.owner.uuid,
          "library_uuid" => ctx.library.uuid
        },
        extra
      )
    end

    test "after the last attempt the error is final and the staged file goes", ctx do
      staged = stage!()
      buckets(false, ctx.bucket)

      assert :ok =
               Oban.Testing.perform_job(StoreUploadJob, args(staged, ctx),
                 repo: TestRepo,
                 attempt: 8
               )

      refute File.exists?(staged)
    end

    test "a refusal is final at once, and an account that cannot sign in stores nothing", ctx do
      staged = stage!()

      stranger =
        confirmed(user_fixture("bg-stranger-#{System.unique_integer([:positive])}@example.com"))

      assert :ok =
               Oban.Testing.perform_job(
                 StoreUploadJob,
                 args(staged, ctx, %{"user_uuid" => stranger.uuid}),
                 repo: TestRepo
               )

      refute File.exists?(staged)
      assert library_files(ctx.library) == []
    end

    test "a path outside the staging directory is never touched", ctx do
      outside =
        Path.join(System.tmp_dir!(), "pk_photos_outside_#{System.unique_integer([:positive])}")

      File.write!(outside, @png)
      on_exit(fn -> File.rm(outside) end)

      assert :ok = Oban.Testing.perform_job(StoreUploadJob, args(outside, ctx), repo: TestRepo)
      assert File.exists?(outside)
      assert library_files(ctx.library) == []
    end
  end

  describe "UploadStaging" do
    test "a sweep removes old leftovers and keeps young ones and those a job waits for", ctx do
      old = stage!()
      waited_for = stage!()
      young = stage!()
      week_ago = System.os_time(:second) - 7 * 86_400

      for path <- [old, waited_for], do: File.touch!(path, week_ago)

      assert UploadStaging.sweep(MapSet.new([waited_for])) == 1
      refute File.exists?(old)
      assert File.exists?(waited_for)
      assert File.exists?(young)
      assert ctx.staging == UploadStaging.dir()
    end

    test "the sweep job runs against the jobs table, and one at most is waiting", _ctx do
      assert :ok = Oban.Testing.perform_job(StagingSweepJob, %{}, repo: TestRepo)

      StagingSweepJob.schedule()
      StagingSweepJob.schedule()
      assert [_one] = Oban.Testing.all_enqueued(repo: TestRepo, worker: StagingSweepJob)
    end
  end
end
