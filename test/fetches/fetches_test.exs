defmodule PhoenixKitPhotos.FetchesTest do
  @moduledoc """
  Fetching from a link end to end, against the database and a real local bucket: the
  look, the confirmation, the download and the storing, cancel, retry, one at a time per
  person, logins and housekeeping. yt-dlp and gallery-dl are the fakes in
  `test/support/fake_tools` (they print what the real ones print and make real files),
  so nothing here touches the network. Jobs run in this process (`perform/1`); Oban is
  started in manual testing mode only to take the inserts.
  """
  use PhoenixKitPhotos.DataCase, async: false

  import Ecto.Query

  alias PhoenixKit.Activity.Entry
  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Modules.Storage.Bucket
  alias PhoenixKit.Modules.Storage.File, as: StorageFile
  alias PhoenixKit.Modules.Storage.FileDetails
  alias PhoenixKitPhotos.Fetches
  alias PhoenixKitPhotos.Fetches.{Fetch, FetchJob, Item, Notify, ProbeJob, SiteLogin, SiteLogins}

  @buckets_cache :phoenix_kit_buckets_cache
  @tools Path.expand("../support/fake_tools", __DIR__)

  defmodule Host do
    @moduledoc false
    def finished(fetch) do
      if pid = :persistent_term.get({__MODULE__, :pid}, nil),
        do: send(pid, {:finished, fetch.uuid, fetch.status})

      :ok
    end

    def link(fetch), do: "/library/#{fetch.library_uuid}"

    def looked(fetch) do
      if pid = :persistent_term.get({__MODULE__, :pid}, nil),
        do: send(pid, {:looked, fetch.uuid, fetch.status})

      :ok
    end
  end

  setup do
    start_supervised!(PhoenixKit.PubSub.Manager)
    start_supervised!({Oban, name: Oban, repo: TestRepo, testing: :manual})

    :persistent_term.erase(@buckets_cache)
    n = System.unique_integer([:positive])
    root = Path.join(System.tmp_dir!(), "pk_fetch_bucket_#{n}")
    work = Path.join(System.tmp_dir!(), "pk_fetch_work_#{n}")
    log = Path.join(work, "args.log")
    File.mkdir_p!(work)

    TestRepo.update_all(Bucket, set: [enabled: false])

    {:ok, _} =
      Storage.create_bucket(%{
        name: "fetch-#{n}",
        provider: "local",
        endpoint: root,
        enabled: true,
        priority: 0
      })

    previous = Application.get_env(:phoenix_kit_photos, Fetches)

    Application.put_env(:phoenix_kit_photos, Fetches,
      enabled: true,
      proxy: "http://127.0.0.1:4750",
      yt_dlp: Path.join(@tools, "yt-dlp"),
      gallery_dl: Path.join(@tools, "gallery-dl"),
      js_runtimes: nil,
      work_dir: work,
      stall_s: 600,
      on_finished: {Host, :finished},
      on_looked: {Host, :looked},
      link: {Host, :link}
    )

    System.put_env("FAKE_LOG", log)
    System.put_env("FAKE_MODE", "album")
    :persistent_term.put({Host, :pid}, self())

    on_exit(fn ->
      :persistent_term.erase(@buckets_cache)
      :persistent_term.erase({Host, :pid})

      if previous,
        do: Application.put_env(:phoenix_kit_photos, Fetches, previous),
        else: Application.delete_env(:phoenix_kit_photos, Fetches)

      System.delete_env("FAKE_LOG")
      System.delete_env("FAKE_MODE")
      File.rm_rf(root)
      File.rm_rf(work)
    end)

    owner = confirmed_user_fixture("fetcher-#{n}@example.com")
    library = library_fixture(owner)
    %{n: n, owner: owner, scope: scope_for(owner), library: library, log: log, work: work}
  end

  defp mode(mode), do: System.put_env("FAKE_MODE", mode)

  defp calls(ctx) do
    case File.read(ctx.log) do
      {:ok, text} -> text |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)
      _ -> []
    end
  end

  defp probe!(fetch) do
    assert :ok = ProbeJob.perform(%Oban.Job{args: %{"fetch" => fetch.uuid}})
    TestRepo.get!(Fetch, fetch.uuid)
  end

  defp started!(ctx, url \\ "https://site.example/album/1") do
    assert {:ok, fetch} = Fetches.start(ctx.scope, ctx.library.uuid, url)
    probe!(fetch)
  end

  defp run!(fetch) do
    assert :ok = FetchJob.perform(%Oban.Job{args: %{"fetch" => fetch.uuid}})
    TestRepo.get!(Fetch, fetch.uuid)
  end

  defp library_files(library) do
    TestRepo.all(
      from(f in StorageFile,
        where: f.library_uuid == ^library.uuid,
        order_by: f.original_file_name
      )
    )
  end

  describe "start/4" do
    test "makes the row and queues the look", ctx do
      Fetches.subscribe(ctx.scope)

      assert {:ok, fetch} =
               Fetches.start(
                 ctx.scope,
                 ctx.library.uuid,
                 "have a look: https://site.example/album/1"
               )

      assert fetch.status == "probing"
      assert fetch.url == "https://site.example/album/1"
      assert fetch.site == "site.example"
      assert_receive {:phoenix_kit_photos_fetch, %Fetch{uuid: uuid}} when uuid == fetch.uuid

      assert TestRepo.exists?(
               from(j in Oban.Job,
                 where:
                   j.worker == "PhoenixKitPhotos.Fetches.ProbeJob" and
                     fragment("?->>'fetch' = ?", j.args, ^fetch.uuid)
               )
             )
    end

    test "refuses what is not a link, a library the person may not add to, an unconfirmed email",
         ctx do
      assert {:error, :not_a_link} = Fetches.start(ctx.scope, ctx.library.uuid, "no link here")

      stranger = confirmed_user_fixture("stranger-#{ctx.n}@example.com")

      assert {:error, :not_allowed} =
               Fetches.start(scope_for(stranger), ctx.library.uuid, "https://a.example/1")

      fresh = user_fixture("unconfirmed-#{ctx.n}@example.com")
      own = library_fixture(fresh)

      assert {:error, :email_unconfirmed} =
               Fetches.start(scope_for(fresh), own.uuid, "https://a.example/1")
    end

    test "does nothing while fetching is off, or without a proxy", ctx do
      config = Application.get_env(:phoenix_kit_photos, Fetches)

      Application.put_env(:phoenix_kit_photos, Fetches, Keyword.put(config, :enabled, false))

      assert {:error, :unavailable} =
               Fetches.start(ctx.scope, ctx.library.uuid, "https://a.example/1")

      Application.put_env(:phoenix_kit_photos, Fetches, Keyword.put(config, :proxy, ""))

      assert {:error, :unavailable} =
               Fetches.start(ctx.scope, ctx.library.uuid, "https://a.example/1")

      refute Fetches.available?()
    end
  end

  describe "the look (ProbeJob)" do
    test "an album through gallery-dl, every request through the proxy", ctx do
      fetch = started!(ctx)

      assert fetch.status == "ready"
      assert fetch.tool == "gallery_dl"
      assert fetch.info["kind"] == "collection"

      assert [
               %{"index" => 1, "key" => "a", "title" => "First photo", "author" => "Ann Author"},
               %{"key" => "b"},
               %{"key" => "c"}
             ] =
               fetch.info["entries"]

      assert [args] = calls(ctx)
      assert ["--proxy", "http://127.0.0.1:4750" | _] = args
      refute File.exists?(Path.join([ctx.work, fetch.uuid, "probe"]))
      assert_receive {:looked, uuid, "ready"} when uuid == fetch.uuid
    end

    test "a video: gallery-dl does not know the site, yt-dlp does", ctx do
      mode("video")
      fetch = started!(ctx, "https://video.example/watch/1")

      assert fetch.status == "ready"
      assert fetch.tool == "yt_dlp"
      assert fetch.info["kind"] == "single"
      assert fetch.info["sizes"] == %{"default" => 650_000, "best" => 2_450_000}
      assert fetch.info["heights"] == %{"default" => 1080, "best" => 2160}
      assert [gdl, ytdlp] = calls(ctx)
      assert "--config-ignore" in gdl
      assert "--ignore-config" in ytdlp
    end

    test "what cannot be fetched says why", ctx do
      for {mode, code} <- [
            {"login", "needs_login"},
            {"blocked", "blocked"},
            {"unsupported", "unsupported"},
            {"video_long", "too_long"}
          ] do
        mode(mode)
        fetch = started!(ctx, "https://#{mode}.example/1")

        assert {fetch.status, fetch.error_code} == {"unavailable", code},
               "#{mode}: #{inspect({fetch.status, fetch.error_code})}"

        assert is_binary(Fetches.error_message(fetch))
        assert_receive {:looked, _, "unavailable"}
      end
    end
  end

  describe "confirm/3" do
    test "refused without the rights confirmation, and before the look is done", ctx do
      {:ok, probing} = Fetches.start(ctx.scope, ctx.library.uuid, "https://site.example/album/1")
      assert {:error, :not_ready} = Fetches.confirm(ctx.scope, probing.uuid, %{"rights" => true})

      fetch = probe!(probing)
      assert {:error, :rights} = Fetches.confirm(ctx.scope, fetch.uuid, %{})
      assert {:error, :rights} = Fetches.confirm(ctx.scope, fetch.uuid, %{"rights" => "false"})

      assert {:error, :no_items} =
               Fetches.confirm(ctx.scope, fetch.uuid, %{"rights" => true, "items" => ["9"]})

      stranger = confirmed_user_fixture("other-#{ctx.n}@example.com")

      assert {:error, :not_found} =
               Fetches.confirm(scope_for(stranger), fetch.uuid, %{"rights" => true})
    end

    test "records the confirmation and the choices, and queues the fetch", ctx do
      fetch = started!(ctx)

      assert {:ok, queued} =
               Fetches.confirm(ctx.scope, fetch.uuid, %{
                 "rights" => "true",
                 "items" => ["1", "3"],
                 "quality" => "best"
               })

      assert queued.status == "queued"
      assert queued.choices == %{"items" => [1, 3], "quality" => "best"}
      assert queued.rights_wording == Fetches.rights_wording()
      assert %NaiveDateTime{} = queued.rights_confirmed_at

      assert TestRepo.exists?(
               from(j in Oban.Job,
                 where:
                   j.worker == "PhoenixKitPhotos.Fetches.FetchJob" and
                     fragment("?->>'fetch' = ?", j.args, ^fetch.uuid)
               )
             )
    end
  end

  describe "the fetch (FetchJob)" do
    test "stores the chosen photos, with their titles, sources and dates", ctx do
      fetch = started!(ctx)
      {:ok, _} = Fetches.confirm(ctx.scope, fetch.uuid, %{"rights" => true, "items" => [1, 3]})
      done = run!(fetch)

      assert done.status == "done"
      assert %{"saved" => 2, "failed" => 0, "duplicates" => 0} = done.progress
      assert [_, fetch_args] = calls(ctx)

      assert ["--filter", ~s(filename in {"a", "c"})] ==
               Enum.slice(fetch_args, Enum.find_index(fetch_args, &(&1 == "--filter")), 2)

      files = library_files(ctx.library)

      assert Enum.sort(Enum.map(files, & &1.original_file_name)) == [
               "First photo 2019-05-01 10.20.30.png",
               "c.png"
             ]

      first = Enum.find(files, &(&1.original_file_name =~ "First"))

      assert FileDetails.translated_title(TestRepo.get!(StorageFile, first.uuid)) == "First photo"

      assert %{
               url: "https://site.example/p/a",
               site: "site.example",
               author: "Ann Author",
               title: "First photo"
             } =
               Fetches.source_for(first.uuid)

      assert [%Item{position: 1, status: "stored"}, %Item{position: 3, status: "stored"}] =
               Fetches.items(done)

      # Core's viewer lists where it came from (`config :phoenix_kit, :media_file_info`).
      assert [
               %{
                 label: "Source:",
                 text: "site.example · by Ann Author",
                 href: "https://site.example/p/a"
               },
               %{label: "Posted:", text: "1 May 2019"}
             ] = Fetches.file_info(first)

      assert [] == Fetches.file_info(%{uuid: Ecto.UUID.generate()})
      assert_receive {:finished, uuid, "done"} when uuid == done.uuid
      refute File.exists?(Path.join(ctx.work, done.uuid))
    end

    test "a video is joined, stored and named by when it was posted", ctx do
      mode("video")
      fetch = started!(ctx, "https://video.example/watch/1")
      {:ok, _} = Fetches.confirm(ctx.scope, fetch.uuid, %{"rights" => true})
      done = run!(fetch)

      assert done.status == "done"
      assert [file] = library_files(ctx.library)
      assert file.original_file_name == "A fake video 2005-04-24 03.31.52.mp4"
      assert file.file_type == "video"

      assert %{author: "Vic Uploader", url: "https://video.example/watch/1"} =
               Fetches.source_for(file.uuid)
    end

    test "the same files again are counted as already there", ctx do
      fetch = started!(ctx)
      {:ok, _} = Fetches.confirm(ctx.scope, fetch.uuid, %{"rights" => true})
      assert %{status: "done", progress: %{"saved" => 3}} = run!(fetch)

      again = started!(ctx)
      assert again.info["previous"]
      {:ok, _} = Fetches.confirm(ctx.scope, again.uuid, %{"rights" => true})
      assert %{status: "done", progress: %{"saved" => 0, "duplicates" => 3}} = run!(again)
      assert length(library_files(ctx.library)) == 3
    end

    test "nothing brought in: the reason from the tool", ctx do
      mode("video_too_big")
      fetch = started!(ctx, "https://video.example/watch/1")
      {:ok, _} = Fetches.confirm(ctx.scope, fetch.uuid, %{"rights" => true})
      assert %{status: "failed", error_code: "too_big"} = run!(fetch)
    end

    test "waits its turn while another of the person's fetches runs", ctx do
      fetch = started!(ctx)
      {:ok, _} = Fetches.confirm(ctx.scope, fetch.uuid, %{"rights" => true})

      other = started!(ctx, "https://site.example/album/2")

      TestRepo.update_all(from(f in Fetch, where: f.uuid == ^other.uuid),
        set: [status: "running", updated_at: NaiveDateTime.utc_now()]
      )

      assert {:snooze, 15} = FetchJob.perform(%Oban.Job{args: %{"fetch" => fetch.uuid}})
      assert Fetches.waiting_before(TestRepo.get!(Fetch, fetch.uuid)) == 1

      # A running row long silent lost its job: it no longer holds the turn.
      TestRepo.update_all(from(f in Fetch, where: f.uuid == ^other.uuid),
        set: [updated_at: ~N[2020-01-01 00:00:00]]
      )

      assert %{status: "done"} = run!(fetch)
    end

    test "a stalled tool is ended", ctx do
      config = Application.get_env(:phoenix_kit_photos, Fetches)
      Application.put_env(:phoenix_kit_photos, Fetches, Keyword.put(config, :stall_s, 1))
      mode("video_stall")
      fetch = started!(ctx, "https://video.example/watch/1")
      {:ok, _} = Fetches.confirm(ctx.scope, fetch.uuid, %{"rights" => true})
      assert %{status: "failed", error_code: "stalled"} = run!(fetch)
    end
  end

  describe "cancel/2" do
    test "a fetch never confirmed is forgotten", ctx do
      fetch = started!(ctx)
      Fetches.subscribe(ctx.scope)
      assert {:ok, :removed} = Fetches.cancel(ctx.scope, fetch.uuid)
      refute TestRepo.get(Fetch, fetch.uuid)
      assert_receive {:phoenix_kit_photos_fetch_removed, uuid} when uuid == fetch.uuid
    end

    test "a queued fetch is cancelled with its job", ctx do
      fetch = started!(ctx)
      {:ok, _} = Fetches.confirm(ctx.scope, fetch.uuid, %{"rights" => true})
      assert {:ok, %{status: "cancelled"}} = Fetches.cancel(ctx.scope, fetch.uuid)

      assert TestRepo.one(
               from(j in Oban.Job,
                 where:
                   j.worker == "PhoenixKitPhotos.Fetches.FetchJob" and
                     fragment("?->>'fetch' = ?", j.args, ^fetch.uuid),
                 select: j.state
               )
             ) == "cancelled"

      assert :ok = FetchJob.perform(%Oban.Job{args: %{"fetch" => fetch.uuid}})
      assert %{status: "cancelled"} = TestRepo.get!(Fetch, fetch.uuid)
    end

    test "a running fetch stops, and the tool's children go with it", ctx do
      mode("video_slow")
      fetch = started!(ctx, "https://video.example/watch/1")
      {:ok, _} = Fetches.confirm(ctx.scope, fetch.uuid, %{"rights" => true})
      Fetches.subscribe(ctx.scope)

      task = Task.async(fn -> FetchJob.perform(%Oban.Job{args: %{"fetch" => fetch.uuid}}) end)

      assert_receive {:phoenix_kit_photos_fetch,
                      %Fetch{status: "running", progress: %{"bytes" => b}}}
                     when is_integer(b) and b > 0,
                     10_000

      child =
        Path.join([ctx.work, fetch.uuid, "files", "child.pid"]) |> File.read!() |> String.trim()

      assert {:ok, %{status: "cancelled"}} = Fetches.cancel(ctx.scope, fetch.uuid)
      assert :ok = Task.await(task, 15_000)

      assert %{status: "cancelled"} = TestRepo.get!(Fetch, fetch.uuid)
      stat = File.read("/proc/#{child}/stat")
      assert match?({:error, _}, stat) or elem(stat, 1) =~ ~r/\) Z/
    end
  end

  describe "retry/2" do
    test "fetches only what is not in yet", ctx do
      fetch = started!(ctx)
      {:ok, _} = Fetches.confirm(ctx.scope, fetch.uuid, %{"rights" => true})
      done = run!(fetch)
      assert {:error, :nothing_missing} = Fetches.retry(ctx.scope, done.uuid)

      TestRepo.delete_all(from(i in Item, where: i.fetch_uuid == ^done.uuid and i.position == 2))
      TestRepo.update_all(from(f in Fetch, where: f.uuid == ^done.uuid), set: [status: "failed"])

      assert {:ok, queued} = Fetches.retry(ctx.scope, done.uuid)
      assert queued.status == "queued"
      assert queued.choices["items"] == [2]
    end

    test "a look that failed is looked at again", ctx do
      mode("blocked")
      fetch = started!(ctx)
      assert fetch.status == "unavailable"
      mode("album")
      assert {:ok, %{status: "probing"}} = Fetches.retry(ctx.scope, fetch.uuid)
      assert %{status: "ready"} = probe!(fetch)
    end
  end

  describe "the person's lists" do
    test "cards of a library, dismissing, and nobody else's", ctx do
      fetch = started!(ctx)
      {:ok, _} = Fetches.confirm(ctx.scope, fetch.uuid, %{"rights" => true})
      done = run!(fetch)

      assert [%{uuid: uuid}] = Fetches.for_library(ctx.scope, ctx.library.uuid)
      assert uuid == done.uuid
      assert [_] = Fetches.list(ctx.scope)

      stranger = confirmed_user_fixture("nosy-#{ctx.n}@example.com")
      assert [] == Fetches.for_library(scope_for(stranger), ctx.library.uuid)
      assert {:error, :not_found} = Fetches.dismiss(scope_for(stranger), done.uuid)

      assert {:ok, _} = Fetches.dismiss(ctx.scope, done.uuid)
      assert [] == Fetches.for_library(ctx.scope, ctx.library.uuid)
      assert [] == Fetches.list(ctx.scope)
    end
  end

  describe "site logins" do
    @cookies ".site.example\tTRUE\t/\tTRUE\t0\tsessionid\ts3cret\n.bank.example\tTRUE\t/\tTRUE\t0\tsession\tnope\n"

    test "kept to the site, encrypted, never listed, written only for the fetch", ctx do
      assert {:ok, login} = SiteLogins.put(ctx.scope, "https://www.site.example/x", @cookies)
      assert login.site == "site.example"
      assert login.cookie_count == 1
      assert login.cookies == nil

      stored =
        TestRepo.one!(from(l in SiteLogin, where: l.uuid == ^login.uuid, select: l.cookies))

      refute stored =~ "s3cret"
      assert [%{site: "site.example", cookies: nil}] = SiteLogins.list(ctx.scope)

      fetch = started!(ctx)
      assert fetch.status == "ready"
      assert [args] = calls(ctx)
      cookies_at = Enum.at(args, Enum.find_index(args, &(&1 == "--cookies")) + 1)
      refute File.exists?(cookies_at), "the cookie file outlives the look"
      assert TestRepo.one!(from(l in SiteLogin, where: l.uuid == ^login.uuid)).last_worked_at

      dir = Path.join(ctx.work, "c")
      path = SiteLogins.cookie_file(to_string(ctx.owner.uuid), "https://site.example/a", dir)
      assert File.read!(path) =~ "sessionid\ts3cret"
      refute File.read!(path) =~ "nope"
      assert {:ok, %{mode: mode}} = File.stat(path)
      assert Bitwise.band(mode, 0o077) == 0

      assert {:error, :empty} = SiteLogins.put(ctx.scope, "x.com", @cookies)
      assert :ok = SiteLogins.delete(ctx.scope, "site.example")
      assert [] == SiteLogins.list(ctx.scope)
    end
  end

  describe "housekeeping and notifications" do
    test "sweep forgets old unconfirmed looks and ends fetches whose job died", ctx do
      old = started!(ctx)

      TestRepo.update_all(from(f in Fetch, where: f.uuid == ^old.uuid),
        set: [updated_at: ~N[2020-01-01 00:00:00]]
      )

      dead = started!(ctx, "https://site.example/album/2")

      TestRepo.update_all(from(f in Fetch, where: f.uuid == ^dead.uuid),
        set: [status: "running", updated_at: ~N[2020-01-01 00:00:00]]
      )

      assert :ok = Fetches.sweep()
      refute TestRepo.get(Fetch, old.uuid)
      assert %{status: "failed", error_code: "stalled"} = TestRepo.get!(Fetch, dead.uuid)
    end

    test "a long fetch rings the bell; every ended fetch reaches the host", ctx do
      fetch = started!(ctx)
      now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

      long = %{
        fetch
        | status: "done",
          started_at: NaiveDateTime.add(now, -120),
          finished_at: now,
          progress: %{"saved" => 2}
      }

      assert Notify.long?(long)
      assert :ok = Notify.finished(long)
      assert_receive {:finished, _, "done"}

      assert %{metadata: %{"notification_text" => text, "notification_link" => link}} =
               TestRepo.one!(
                 from(e in Entry,
                   where: e.action == "photos.fetch_done" and e.resource_uuid == ^fetch.uuid
                 )
               )

      assert text =~ "site.example"
      assert link == "/library/#{ctx.library.uuid}"

      short = %{long | started_at: NaiveDateTime.add(now, -5)}
      refute Notify.long?(short)
    end
  end
end
