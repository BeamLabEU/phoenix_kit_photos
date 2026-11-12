defmodule PhoenixKitPhotos.Fetches.FetchJob do
  @moduledoc """
  Downloads a confirmed fetch and stores what it brings in. Runs in the `photo_fetches`
  queue (the host declares it: `photo_fetches: 3` lets three run on a node).

  ## One at a time per person

  A job takes its turn under a Postgres advisory lock on the person: while another of
  their fetches is `"running"`, it snoozes 15 s and tries again (Oban does not count a
  snooze as an attempt). A running row silent well past the stall limit does not hold
  the turn: its job died.

  ## While it runs

  The tool runs in `PhoenixKitPhotos.Fetches.Runner`, in the fetch's own folder
  (`Config.work_dir/1`), and every line it prints comes here. Progress is written to the
  row and broadcast at most once a second (`Fetches.subscribe/1`). Each file is stored
  as soon as it is finished (`Uploads.store/4`, as the person, who is read again and
  must still be allowed to add to the library), recorded as an `Item` with where it came
  from, and deleted from the folder. So a fetch that fails at the thirtieth file keeps
  twenty-nine, and `Fetches.retry/2` fetches only the rest.

  A stored file is named `<title> <posted date>.<ext>`: core dates a file by its own
  capture date first, and only a file that has none (a merged video, a photo whose site
  stripped EXIF) by the date in its name (`PhoenixKit.Modules.Storage.CaptureDate`).
  The title also becomes the file's title.

  ## Stopping

  `Fetches.cancel/2` sends `:cancel` on the fetch's control topic: the tool is ended,
  the file in hand is still stored, and the fetch stays `"cancelled"`. Running out of
  storage (`:quota_exceeded`) or losing the right to add ends it as `"failed"`. A tool
  that says nothing for `:stall_s` is ended (`"stalled"`).

  The job never asks Oban to retry an ended fetch: the person has Retry for that. A job
  that crashed or was timed out runs again (up to 3 attempts), and yt-dlp continues the
  partial download it left.
  """

  use Oban.Worker,
    queue: :photo_fetches,
    max_attempts: 3,
    unique: [
      keys: [:fetch],
      period: :infinity,
      states: [:available, :scheduled, :executing, :retryable]
    ]

  import Ecto.Query

  require Logger

  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Modules.Storage.ProcessFileJob
  alias PhoenixKit.PubSub.Manager
  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.Auth.{SessionRef, User}
  alias PhoenixKitPhotos.Fetches

  alias PhoenixKitPhotos.Fetches.{
    Config,
    Errors,
    Fetch,
    GalleryDl,
    Item,
    Meta,
    Notify,
    Runner,
    SiteLogins,
    YtDlp
  }

  alias PhoenixKitPhotos.Uploads

  @snooze_s 15
  @write_every_ms 1_000
  @dead_grace_s 15 * 60

  @impl Oban.Worker
  def timeout(_job), do: Config.get(:job_timeout_ms)

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"fetch" => uuid}}) do
    case Fetches.get_any(uuid) do
      %Fetch{status: status} = fetch when status in ["queued", "running"] ->
        case claim(fetch) do
          {:ok, fetch} -> run(fetch)
          :busy -> {:snooze, @snooze_s}
          :gone -> :ok
        end

      _ended_or_gone ->
        :ok
    end
  end

  # ── Taking the person's turn ───────────────────────────────────────────

  defp claim(fetch) do
    repo = Fetches.repo()

    repo.transaction(fn -> take_turn(repo, fetch) end)
    |> case do
      {:ok, {:ok, fetch}} ->
        Fetches.broadcast(fetch)
        {:ok, fetch}

      {:ok, other} ->
        other

      {:error, reason} ->
        Logger.warning("[Fetches] could not take a turn for #{fetch.uuid}: #{inspect(reason)}")
        :busy
    end
  end

  # Inside the transaction, under the person's lock: `{:ok, running}`, `:busy` or `:gone`.
  defp take_turn(repo, fetch) do
    repo.query!("SELECT pg_advisory_xact_lock(hashtext($1))", [
      "phoenix_kit_photos_fetch:" <> to_string(fetch.user_uuid)
    ])

    current = repo.get(Fetch, fetch.uuid)

    cond do
      is_nil(current) or current.status not in ["queued", "running"] -> :gone
      others_running(repo, fetch) >= Config.get(:per_user) -> :busy
      true -> start_running(current)
    end
  end

  # The person's other fetches that run and are alive (heard from within the stall limit).
  defp others_running(repo, fetch) do
    alive_since = NaiveDateTime.add(Fetches.now(), -(Config.get(:stall_s) + @dead_grace_s))

    repo.aggregate(
      from(f in Fetch,
        where:
          f.user_uuid == ^fetch.user_uuid and f.uuid != ^fetch.uuid and
            f.status == "running" and f.updated_at > ^alive_since
      ),
      :count
    )
  end

  defp start_running(fetch) do
    Fetches.write(
      fetch,
      %{
        status: "running",
        started_at: fetch.started_at || Fetches.now(),
        progress: Map.merge(fetch.progress || %{}, %{"phase" => "starting"})
      },
      broadcast: false
    )
  end

  # ── Running ────────────────────────────────────────────────────────────

  defp run(%Fetch{} = fetch) do
    dir = Config.work_dir(fetch.uuid)
    files = Path.join(dir, "files")
    Runner.kill_leftover(dir)
    File.mkdir_p!(files)
    File.rm(Path.join(dir, "stderr.log"))
    Manager.subscribe(Fetches.control_topic(fetch.uuid))

    try do
      case scope_for(fetch) do
        {:ok, scope} ->
          download(fetch, scope, dir, files)

        {:error, code} ->
          finish(fetch, "failed", code, nil, %{})
      end
    after
      Manager.unsubscribe(Fetches.control_topic(fetch.uuid))
      File.rm(Path.join(dir, "cookies.txt"))
      ended = Fetches.get_any(fetch.uuid)
      if is_nil(ended) or ended.status not in ["queued", "running"], do: File.rm_rf(dir)
    end

    :ok
  end

  defp scope_for(fetch) do
    with %User{} = user <- Auth.get_user(fetch.user_uuid),
         {:ok, scope} <- SessionRef.scope_for_user(user),
         :ok <- Fetches.may_add(scope, fetch.library_uuid) do
      {:ok, scope}
    else
      {:error, :unconfirmed} -> {:error, "email_unconfirmed"}
      {:error, :email_unconfirmed} -> {:error, "email_unconfirmed"}
      _ -> {:error, "not_allowed"}
    end
  end

  defp download(fetch, scope, dir, files) do
    cookies = SiteLogins.cookie_file(to_string(fetch.user_uuid), fetch.url, dir)
    picked = picked(fetch)
    keys = keys(fetch, picked)
    {tool, args} = command(fetch, files, cookies, picked, keys)

    {runner, ref} =
      Runner.start(Config.executable(tool), args, dir: dir, stall_ms: Config.get(:stall_s) * 1000)

    state =
      fetch
      |> initial_state(picked, keys)
      |> Map.merge(%{scope: scope, tool: tool, runner: runner, ref: ref, files: files})
      |> loop()

    stderr = Runner.stderr_tail(dir)
    if cookies, do: mark_login(fetch, state, stderr)
    conclude(state, stderr)
  end

  defp picked(fetch) do
    (fetch.choices || %{})["items"] || for(%{"index" => i} <- entries(fetch), do: i)
  end

  defp entries(fetch), do: (fetch.info || %{})["entries"] || []

  defp command(fetch, files, cookies, picked, keys) do
    opts = [
      proxy: Config.proxy(),
      max_items: Config.get(:max_items),
      cookies: cookies,
      quality: (fetch.choices || %{})["quality"],
      items: picked,
      keys: keys
    ]

    case fetch.tool do
      "yt_dlp" -> {:yt_dlp, YtDlp.fetch_args(fetch.url, files, opts)}
      _ -> {:gallery_dl, GalleryDl.fetch_args(fetch.url, files, opts)}
    end
  end

  defp initial_state(fetch, picked, keys) do
    %{
      fetch: fetch,
      picked: picked,
      entries: Map.new(entries(fetch), &{&1["index"], &1}),
      by_key: if(keys, do: Map.new(entries(fetch), &{&1["key"], &1["index"]}), else: %{}),
      position: nil,
      started: 0,
      stop: nil,
      written_at: 0,
      progress:
        Map.merge(fetch.progress || %{}, %{
          "phase" => "downloading",
          "items" => length(picked),
          "item" => 0,
          "saved" => 0,
          "duplicates" => 0,
          "failed" => 0
        })
    }
  end

  # The names of the chosen files, when every file of the look has one of its own (see
  # `GalleryDl`); nil otherwise, and the fetch picks by number.
  defp keys(%Fetch{tool: "gallery_dl", info: info}, picked) do
    entries = info["entries"] || []
    all = Enum.map(entries, & &1["key"])

    if Enum.all?(all, &is_binary/1) and length(Enum.uniq(all)) == length(all) do
      wanted = MapSet.new(picked)
      for %{"index" => i, "key" => key} <- entries, MapSet.member?(wanted, i), do: key
    end
  end

  defp keys(_fetch, _picked), do: nil

  defp loop(%{ref: ref} = state) do
    receive do
      {^ref, {:line, line}} ->
        state |> line(line) |> write(false) |> loop()

      {^ref, {:exit, status}} ->
        Map.put(state, :exit, status)

      :cancel ->
        Runner.cancel(state.runner)
        loop(%{state | stop: state.stop || "cancelled"})

      _other ->
        loop(state)
    end
  end

  # yt-dlp's lines
  defp line(%{tool: :yt_dlp} = state, text) do
    case YtDlp.parse_line(text) do
      {:item, index} ->
        next_item(state, index)

      {:progress, p} ->
        put_progress(state, %{
          "phase" => "downloading",
          "bytes" => p.bytes,
          "total_bytes" => p.total,
          "speed" => p.speed,
          "eta" => p.eta
        })

      {:postprocess, "started", "Merger"} ->
        state
        |> put_progress(%{"phase" => "joining", "speed" => nil, "eta" => nil})
        |> write(true)

      {:file, path, meta} ->
        store(state, path, meta, meta["playlist_index"] || state.position || 1)

      _ ->
        state
    end
  end

  # gallery-dl's lines
  defp line(%{tool: :gallery_dl} = state, text) do
    case GalleryDl.parse_line(text) do
      {:item, _category} ->
        state = %{state | started: state.started + 1}

        put_progress(state, %{
          "phase" => "downloading",
          "item" => state.started,
          "bytes" => nil,
          "total_bytes" => nil
        })

      {:file, path} ->
        meta = GalleryDl.sidecar(path)
        # By name when the files were chosen by name; else the n-th file is the n-th chosen.
        position =
          Map.get(state.by_key, meta["filename"]) || Enum.at(state.picked, state.started - 1) ||
            state.started

        store(state, path, meta, position)

      _ ->
        state
    end
  end

  defp next_item(state, index) do
    shown = Enum.find_index(state.picked, &(&1 == index))
    title = get_in(state.entries, [index, "title"])

    %{state | position: index}
    |> put_progress(%{
      "phase" => "downloading",
      "item" => if(shown, do: shown + 1, else: state.progress["item"] + 1),
      "title" => title,
      "bytes" => nil,
      "total_bytes" => nil,
      "speed" => nil,
      "eta" => nil
    })
    |> write(true)
  end

  defp put_progress(state, changes), do: %{state | progress: Map.merge(state.progress, changes)}

  # Writes progress and tells the pages, at most once a second unless `force`.
  defp write(state, force) do
    now = System.monotonic_time(:millisecond)

    if force or now - state.written_at >= @write_every_ms do
      case Fetches.put_progress(state.fetch, state.progress) do
        {:ok, fetch} -> %{state | fetch: fetch, written_at: now}
        _ -> %{state | written_at: now}
      end
    else
      state
    end
  end

  # ── Storing a file ────────────────────────────────────────────────────

  defp store(state, path, meta, position) do
    path = Path.expand(path, state.files)

    if inside?(path, state.files) and File.regular?(path) do
      state = state |> put_progress(%{"phase" => "saving"}) |> write(true)
      posted_at = Meta.posted_at(meta) || posted_from_entry(state, position)
      title = Meta.title(meta) || get_in(state.entries, [position, "title"])
      name = file_name(title, posted_at, path)
      entry = %{client_name: name, client_type: MIME.from_path(path)}

      result = Uploads.store(path, entry, state.scope, state.fetch.library_uuid)
      after_store(result, path, title)

      item = %{
        fetch_uuid: state.fetch.uuid,
        position: position,
        source_url: source_url(meta, state.fetch),
        title: title,
        author:
          Meta.author(meta) || get_in(state.entries, [position, "author"]) ||
            state.fetch.info["author"],
        posted_at: posted_at
      }

      File.rm(path)
      File.rm(path <> ".json")
      record(state, result, item)
    else
      Logger.warning(
        "[Fetches] a tool reported a file outside its folder or not there: #{inspect(path)}"
      )

      state
    end
  end

  defp inside?(path, dir), do: String.starts_with?(path, Path.expand(dir) <> "/")

  # The look's date for this entry; the whole link's date only for a single post (a
  # collection's is its first file's, and would date every undated file like that one).
  defp posted_from_entry(state, position) do
    fallback = if state.fetch.info["kind"] == "single", do: state.fetch.info["posted_at"]

    case get_in(state.entries, [position, "posted_at"]) || fallback do
      iso when is_binary(iso) ->
        case NaiveDateTime.from_iso8601(iso) do
          {:ok, dt} -> dt
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp source_url(meta, fetch) do
    Enum.find_value(["webpage_url", "post_url", "page_url"], &http_url(meta[&1])) || fetch.url
  end

  defp http_url("http://" <> _ = url), do: url
  defp http_url("https://" <> _ = url), do: url
  defp http_url(_value), do: nil

  @doc false
  # `<title> <posted date>.<ext>`: see the moduledoc. A date without a time of day
  # (yt-dlp's `upload_date`) is written as a date only.
  def file_name(title, posted_at, path) do
    ext = path |> Path.extname() |> String.downcase()

    base =
      (title || Path.rootname(Path.basename(path)))
      |> String.replace(~r/[\x00-\x1F\x7F\/\\:*?"<>|#%]+/u, " ")
      |> String.replace(~r/\s+/u, " ")
      |> String.trim()
      |> String.trim(".")
      |> String.slice(0, 80)
      |> String.trim()

    base = if base == "", do: "fetched", else: base

    case posted_at do
      %NaiveDateTime{hour: 0, minute: 0, second: 0} = at ->
        "#{base} #{Calendar.strftime(at, "%Y-%m-%d")}#{ext}"

      %NaiveDateTime{} = at ->
        "#{base} #{Calendar.strftime(at, "%Y-%m-%d %H.%M.%S")}#{ext}"

      _ ->
        base <> ext
    end
  end

  # A new file gets the post's title and its date and shape read now, from the local
  # copy, so the timeline places it at once (as `StoreUploadJob` does).
  defp after_store({:added, %{status: "processing"} = file}, path, title) do
    set_title(file, title)

    if Code.ensure_loaded?(ProcessFileJob) and
         function_exported?(ProcessFileJob, :read_metadata, 2),
       do: ProcessFileJob.read_metadata(to_string(file.uuid), path)
  rescue
    error ->
      Logger.warning(
        "[Fetches] reading a stored file's metadata failed: #{Exception.message(error)}"
      )
  end

  defp after_store({:added, file}, _path, title), do: set_title(file, title)
  defp after_store(_result, _path, _title), do: :ok

  defp set_title(_file, nil), do: :ok

  defp set_title(file, title) do
    case Storage.update_file_details(file, %{"title" => title}, managed: :owner) do
      {:ok, _} -> :ok
      other -> Logger.info("[Fetches] could not set a fetched file's title: #{inspect(other)}")
    end
  rescue
    error ->
      Logger.info("[Fetches] could not set a fetched file's title: #{Exception.message(error)}")
  end

  @fatal [:quota_exceeded, :not_allowed, :email_unconfirmed]

  defp record(state, result, item) do
    {status, file_uuid, error} = outcome(result)
    now = Fetches.now()

    Fetches.repo().insert(
      struct(
        Item,
        Map.merge(item, %{
          status: status,
          file_uuid: file_uuid,
          error: error,
          inserted_at: now,
          updated_at: now
        })
      )
    )

    counter = counter(status)

    state
    |> put_progress(%{counter => (state.progress[counter] || 0) + 1, "phase" => "downloading"})
    |> stop_on(result)
    |> write(true)
  end

  defp outcome({:added, file}), do: {"stored", file.uuid, nil}
  defp outcome({:duplicate, file}), do: {"duplicate", file.uuid, nil}
  defp outcome({:elsewhere, file}), do: {"elsewhere", file.uuid, nil}
  defp outcome({:error, reason}), do: {"failed", nil, inspect(reason)}

  defp counter("stored"), do: "saved"
  defp counter("failed"), do: "failed"
  defp counter(_already_there), do: "duplicates"

  # No room left, or no right to add any more: nothing further can be stored.
  defp stop_on(state, {:error, reason}) when reason in @fatal do
    Runner.cancel(state.runner)
    %{state | stop: state.stop || to_string(reason)}
  end

  defp stop_on(state, _result), do: state

  # ── Ending ────────────────────────────────────────────────────────────

  defp conclude(state, stderr) do
    fetch = Fetches.get_any(state.fetch.uuid) || state.fetch
    kept = state.progress["saved"] + state.progress["duplicates"]
    missing = Fetches.missing_items(fetch)
    {status, code, detail} = ending(fetch, state, kept, missing, stderr)

    progress =
      Map.merge(state.progress, %{
        "failed" => length(missing),
        "phase" => if(status == "cancelled", do: "cancelled"),
        "speed" => nil,
        "eta" => nil
      })

    finish(fetch, status, code, detail, progress)
  end

  # `{status, error code, detail}` of an ended fetch, from what stopped it, what it kept
  # (`kept`: stored or already there) and what of the chosen it did not (`missing`).
  defp ending(%Fetch{status: "cancelled"}, _state, _kept, _missing, _stderr),
    do: {"cancelled", nil, nil}

  defp ending(_fetch, %{stop: "cancelled"}, _kept, _missing, _stderr), do: {"cancelled", nil, nil}

  defp ending(_fetch, %{stop: stop}, _kept, _missing, _stderr) when is_binary(stop),
    do: {"failed", stop, nil}

  defp ending(_fetch, %{exit: exit}, kept, _missing, stderr) when exit in [:stalled, :too_much],
    do: {status_for(kept), "stalled", Errors.last_error_line(stderr)}

  defp ending(_fetch, _state, kept, [], _stderr) when kept > 0, do: {"done", nil, nil}

  defp ending(_fetch, _state, kept, _missing, stderr) when kept > 0,
    do: {"done", Errors.classify(stderr), Errors.last_error_line(stderr)}

  defp ending(_fetch, %{exit: 0}, _kept, _missing, stderr),
    do: {"failed", nothing_code(stderr), Errors.last_error_line(stderr)}

  defp ending(_fetch, _state, _kept, _missing, stderr),
    do: {"failed", Errors.classify(stderr), Errors.last_error_line(stderr)}

  defp status_for(kept) when kept > 0, do: "done"
  defp status_for(_kept), do: "failed"

  # The tool ended well and brought nothing: a file over the size limit or a video over
  # the length limit is skipped that way.
  defp nothing_code(stderr) do
    case Errors.classify(stderr) do
      "failed" -> "nothing"
      code -> code
    end
  end

  defp finish(fetch, status, code, detail, progress) do
    attrs = %{
      status: status,
      error_code: code,
      error: detail,
      progress: progress,
      finished_at: Fetches.now()
    }

    case Fetches.write(fetch, attrs) do
      {:ok, ended} ->
        Logger.info(
          "[Fetches] #{ended.uuid} (#{ended.site}) ended #{status}#{if code, do: " (#{code})"}"
        )

        Notify.finished(ended)

      _ ->
        :ok
    end
  end

  defp mark_login(fetch, state, stderr) do
    worked = state.progress["saved"] + state.progress["duplicates"] > 0

    cond do
      worked ->
        SiteLogins.mark(to_string(fetch.user_uuid), fetch.url, :worked)

      Errors.classify(stderr) == "needs_login" ->
        SiteLogins.mark(to_string(fetch.user_uuid), fetch.url, :failed)

      true ->
        :ok
    end
  end
end
