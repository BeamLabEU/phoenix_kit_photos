defmodule PhoenixKitPhotos.Fetches.RealToolsTest do
  @moduledoc """
  The real yt-dlp and gallery-dl, real sites, through the real egress proxy
  (`$FETCH_PROXY`), into a local bucket. Left out by default (it needs the network and
  the tools): `mix test --include real_tools test/fetches/real_tools_test.exs`.
  """
  use PhoenixKitPhotos.DataCase, async: false

  import Ecto.Query

  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Modules.Storage.Bucket
  alias PhoenixKit.Modules.Storage.File, as: StorageFile
  alias PhoenixKitPhotos.Fetches
  alias PhoenixKitPhotos.Fetches.{Fetch, FetchJob, ProbeJob}

  @moduletag :real_tools
  @moduletag timeout: 300_000

  setup do
    proxy = System.get_env("FETCH_PROXY") || flunk("FETCH_PROXY is not set")
    start_supervised!(PhoenixKit.PubSub.Manager)
    start_supervised!({Oban, name: Oban, repo: TestRepo, testing: :manual})
    :persistent_term.erase(:phoenix_kit_buckets_cache)

    n = System.unique_integer([:positive])
    root = Path.join(System.tmp_dir!(), "pk_real_bucket_#{n}")
    work = Path.join(System.tmp_dir!(), "pk_real_work_#{n}")
    TestRepo.update_all(Bucket, set: [enabled: false])

    {:ok, _} =
      Storage.create_bucket(%{
        name: "real-#{n}",
        provider: "local",
        endpoint: root,
        enabled: true,
        priority: 0
      })

    Application.put_env(:phoenix_kit_photos, Fetches, enabled: true, proxy: proxy, work_dir: work)

    on_exit(fn ->
      Application.delete_env(:phoenix_kit_photos, Fetches)
      :persistent_term.erase(:phoenix_kit_buckets_cache)
      File.rm_rf(root)
      File.rm_rf(work)
    end)

    owner = confirmed_user_fixture("real-#{n}@example.com")
    %{scope: scope_for(owner), library: library_fixture(owner)}
  end

  defp fetch!(ctx, url, choices \\ %{}) do
    {:ok, fetch} = Fetches.start(ctx.scope, ctx.library.uuid, url)
    :ok = ProbeJob.perform(%Oban.Job{args: %{"fetch" => fetch.uuid}})
    looked = TestRepo.get!(Fetch, fetch.uuid)

    IO.puts(
      "\n#{url}\n  look: #{looked.status} #{looked.tool} #{looked.error_code} #{inspect(Map.take(looked.info, ~w(kind title author posted_at count sizes heights)))}"
    )

    if looked.status == "ready" do
      {:ok, _} = Fetches.confirm(ctx.scope, fetch.uuid, Map.put(choices, "rights", true))
      :ok = FetchJob.perform(%Oban.Job{args: %{"fetch" => fetch.uuid}})
    end

    done = TestRepo.get!(Fetch, fetch.uuid)
    IO.puts("  end: #{done.status} #{done.error_code} #{inspect(done.progress)}")
    done
  end

  defp files(library),
    do:
      TestRepo.all(
        from(f in StorageFile,
          where: f.library_uuid == ^library.uuid,
          select: {f.original_file_name, f.file_type, f.size}
        )
      )

  test "a Wikimedia Commons photo through gallery-dl", ctx do
    done = fetch!(ctx, "https://commons.wikimedia.org/wiki/File:Example.jpg", %{"items" => [1]})
    assert done.status == "done"
    assert [{name, "image", size}] = files(ctx.library)
    IO.puts("  stored: #{name} (#{size} bytes)")
  end

  test "YouTube's first video through yt-dlp, at the default quality", ctx do
    done = fetch!(ctx, "https://www.youtube.com/watch?v=jNQXAC9IVRw")
    assert done.status == "done"
    assert [{name, "video", size}] = files(ctx.library)
    assert name == "Me at the zoo 2005-04-24 03.31.52.mp4"
    IO.puts("  stored: #{name} (#{size} bytes)")
  end

  test "an internal address is refused by the proxy", ctx do
    # A host without a dot is not a link at all.
    assert {:error, :not_a_link} =
             Fetches.start(ctx.scope, ctx.library.uuid, "http://localhost:4000/images/x.jpg")

    # The metadata address, and a public name that resolves to 127.0.0.1: the proxy says no.
    for url <- [
          "http://169.254.169.254/latest/meta-data/x.png",
          "http://localtest.me:4000/images/x.jpg"
        ] do
      done = fetch!(ctx, url)
      assert done.status == "unavailable"
      assert done.error_code == "address"
    end

    assert files(ctx.library) == []
  end

  test "a plain link to an image file", ctx do
    done = fetch!(ctx, "https://upload.wikimedia.org/wikipedia/commons/a/a9/Example.jpg")
    assert done.status == "done"
    assert done.tool == "gallery_dl"
    assert [{_name, "image", _size}] = files(ctx.library)
  end

  test "Wikimedia lists a file's versions under one name: the one picked is the one fetched",
       ctx do
    done = fetch!(ctx, "https://commons.wikimedia.org/wiki/File:Example.jpg", %{"items" => [2]})
    assert done.status == "done"
    assert %{"saved" => 1, "failed" => 0} = done.progress
    assert [%{position: 2}] = Fetches.items(done)
  end
end
