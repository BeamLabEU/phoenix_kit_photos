defmodule PhoenixKitPhotos.Fetches do
  @moduledoc """
  Fetching photos and videos from a link: a person pastes a link into a library, the
  server looks at it, the person confirms they have the right to keep a copy, and the
  server downloads and stores it. It lives on the server: a refresh, a lost connection
  or a closed tab changes nothing, and every page that shows a fetch reads it from the
  database and then follows it over PubSub. Plan: Fotki's
  `dev_docs/plans/2026-11-12-fetch-from-link.md`.

  ## The way through

    1. `start/4` checks the link (`Link.parse/1`) and that the person may add to the
       library, makes the row (`"probing"`) and queues the look (`ProbeJob`).
    2. The look ends `"ready"` (with `info`: title, author, entries, sizes) or
       `"unavailable"` (with `error_code`).
    3. `confirm/3` takes the person's choices and their confirmation of the right to
       keep a copy (refused without it), records when and which wording
       (`rights_wording/0`), and queues the fetch (`FetchJob`, `"queued"`).
    4. `FetchJob` runs it (`"running"`), one fetch at a time per person, storing each
       file as it arrives, and ends `"done"`, `"failed"` or `"cancelled"`.

  `cancel/2`, `retry/2` and `dismiss/2` are the person's buttons. A fetch belongs to
  the person who started it; nobody else sees or touches it.

  ## Tools and the proxy

  yt-dlp for video sites, gallery-dl for photo sites and plain file links
  (`ProbeJob` picks), every request through the egress proxy
  (`PhoenixKitPhotos.Fetches.Config`). Nothing runs unless the host switched fetching
  on and the proxy and both tools are there (`available?/0`).

  ## Updates

  `subscribe/1` subscribes the caller to a person's fetches; every change arrives as
  `{:phoenix_kit_photos_fetch, %Fetch{}}`, and a fetch that is gone (cancelled before it
  was confirmed) as `{:phoenix_kit_photos_fetch_removed, uuid}`.
  """

  import Ecto.Query

  require Logger

  use Gettext, backend: PhoenixKitPhotos.Gettext

  alias PhoenixKit.PubSub.Manager
  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKitPhotos.Fetches.{Config, Errors, Fetch, FetchJob, Item, Link, ProbeJob, Runner}
  alias PhoenixKitPhotos.Uploads

  # Bump when the confirmation's wording changes: each fetch records which one it showed.
  @rights_wording "2026-11-12"

  # A fetch the person never confirmed is forgotten after this.
  @open_for_hours 24
  # An ended fetch stays on the library's cards this long unless dismissed.
  @card_hours 24
  # A "running" row this much quieter than the stall limit lost its job.
  @dead_grace_s 15 * 60

  @type scope :: Scope.t()

  @doc "Whether fetching is on and can run here (`Config.available/0`)."
  @spec available?() :: boolean()
  defdelegate available?, to: Config

  @doc "The version of the rights wording that `rights_text/0` says."
  @spec rights_wording() :: String.t()
  def rights_wording, do: @rights_wording

  @doc "What a person confirms before a fetch (D5 of the plan)."
  @spec rights_text() :: String.t()
  def rights_text,
    do:
      gettext(
        "I own this, or its owner (or the law) allows me to keep a copy. I am responsible for what I save."
      )

  @doc "The topic of a person's fetches."
  @spec topic(String.t()) :: String.t()
  def topic(user_uuid), do: "phoenix_kit_photos:fetches:" <> to_string(user_uuid)

  @doc false
  def control_topic(fetch_uuid), do: "phoenix_kit_photos:fetch_control:" <> to_string(fetch_uuid)

  @doc "Subscribes the caller to the fetches of the person of `scope` (or a user uuid)."
  @spec subscribe(scope() | String.t()) :: :ok
  def subscribe(%Scope{} = scope), do: subscribe(Scope.user_uuid(scope))

  def subscribe(user_uuid) when is_binary(user_uuid) do
    Manager.subscribe(topic(user_uuid))
    :ok
  end

  def subscribe(_), do: :ok

  # ── The person's actions ───────────────────────────────────────────────

  @doc """
  Starts a fetch of the link in `text` into the library: makes the row and queues the
  look. `opts`: `:origin` (`"web"` or `"telegram"`), `:origin_data` (a map the origin
  needs to answer). `{:ok, fetch}` or `{:error, reason}`: `:unavailable` (fetching is
  off or cannot run here), `:not_a_link`, `:not_allowed`, `:email_unconfirmed`.
  """
  @spec start(scope(), String.t(), String.t(), keyword()) ::
          {:ok, Fetch.t()}
          | {:error, :unavailable | :not_a_link | :not_allowed | :email_unconfirmed | term()}
  def start(scope, library_uuid, text, opts \\ []) do
    with :ok <- available(),
         {:ok, url} <- parse(text),
         :ok <- may_add(scope, library_uuid) do
      attrs = %{
        user_uuid: Scope.user_uuid(scope),
        library_uuid: library_uuid,
        url: url,
        site: Link.site(url),
        status: "probing",
        origin: Keyword.get(opts, :origin, "web"),
        origin_data: Keyword.get(opts, :origin_data, %{})
      }

      attrs
      |> insert_with_job(ProbeJob)
      |> tap(fn
        {:ok, fetch} ->
          broadcast(fetch)
          PhoenixKitPhotos.StagingSweepJob.schedule()

        _ ->
          :ok
      end)
    end
  end

  # The row and its first job, both or neither.
  defp insert_with_job(attrs, worker) do
    repo().transaction(fn ->
      with {:ok, fetch} <- repo().insert(Fetch.create_changeset(attrs)),
           {:ok, _job} <- Oban.insert(worker.new(%{"fetch" => fetch.uuid})) do
        fetch
      else
        {:error, reason} -> repo().rollback(reason)
      end
    end)
  end

  defp available do
    case Config.available() do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.info("[Fetches] fetching is not available here: #{inspect(reason)}")
        {:error, :unavailable}
    end
  end

  defp parse(text) do
    case Link.parse(text) do
      {:ok, url} -> {:ok, url}
      :error -> {:error, :not_a_link}
    end
  end

  @doc false
  def may_add(scope, library_uuid) do
    cond do
      not Uploads.can_upload?(scope, library_uuid) -> {:error, :not_allowed}
      reason = Uploads.blocked(scope) -> {:error, reason}
      true -> :ok
    end
  end

  @doc """
  Confirms a fetch the look found `"ready"` and queues it. `params`:

    * `"rights"` — must be `true` (or `"true"`): the person confirmed `rights_text/0`.
    * `"quality"` — `"default"` (up to 1080p) or `"best"`.
    * `"items"` — the indexes of the entries to fetch (all when absent).

  `{:ok, fetch}`, or `{:error, reason}`: `:not_found`, `:not_ready`, `:rights`,
  `:no_items`, `:not_allowed`, `:email_unconfirmed`.
  """
  @spec confirm(scope(), String.t(), map()) :: {:ok, Fetch.t()} | {:error, atom()}
  def confirm(scope, uuid, params) when is_map(params) do
    with %Fetch{} = fetch <- get(scope, uuid) || {:error, :not_found},
         true <- fetch.status == "ready" || {:error, :not_ready},
         true <- params["rights"] in [true, "true", "on"] || {:error, :rights},
         :ok <- may_add(scope, fetch.library_uuid),
         {:ok, items} <- picked_items(fetch, params["items"]) do
      now = now()

      choices = %{
        "quality" => if(params["quality"] == "best", do: "best", else: "default"),
        "items" => items
      }

      repo().transaction(fn ->
        {1, [fetch]} =
          repo().update_all(
            from(f in Fetch, where: f.uuid == ^fetch.uuid and f.status == "ready", select: f),
            set: [
              status: "queued",
              choices: choices,
              rights_confirmed_at: now,
              rights_wording: @rights_wording,
              progress: %{"phase" => "waiting", "items" => length(items)},
              error_code: nil,
              error: nil,
              updated_at: now
            ]
          )

        {:ok, _} = Oban.insert(FetchJob.new(%{"fetch" => fetch.uuid}))
        fetch
      end)
      |> tap(fn
        {:ok, fetch} -> broadcast(fetch)
        _ -> :ok
      end)
    end
  rescue
    MatchError -> {:error, :not_ready}
  end

  defp picked_items(%Fetch{info: info}, picked) do
    available = for %{"index" => index} <- info["entries"] || [], do: index

    items =
      case picked do
        nil ->
          available

        list when is_list(list) ->
          wanted = list |> Enum.map(&to_index/1) |> MapSet.new()
          Enum.filter(available, &MapSet.member?(wanted, &1))

        _ ->
          []
      end

    if items == [], do: {:error, :no_items}, else: {:ok, items}
  end

  defp to_index(n) when is_integer(n), do: n

  defp to_index(n) when is_binary(n) do
    case Integer.parse(n) do
      {i, ""} -> i
      _ -> nil
    end
  end

  defp to_index(_), do: nil

  @doc """
  Stops a fetch. One the person never confirmed is forgotten (`{:ok, :removed}`); one on
  its way is told to stop and ends `"cancelled"`, keeping what it saved so far.
  """
  @spec cancel(scope(), String.t()) :: {:ok, Fetch.t() | :removed} | {:error, :not_found | :ended}
  def cancel(scope, uuid) do
    case get(scope, uuid) do
      nil ->
        {:error, :not_found}

      %Fetch{status: status} = fetch when status in ["probing", "ready", "unavailable"] ->
        cancel_jobs(fetch.uuid)
        repo().delete_all(from(f in Fetch, where: f.uuid == ^fetch.uuid))
        Manager.broadcast(topic(fetch.user_uuid), {:phoenix_kit_photos_fetch_removed, fetch.uuid})
        {:ok, :removed}

      %Fetch{status: status} = fetch when status in ["queued", "running"] ->
        Manager.broadcast(control_topic(fetch.uuid), :cancel)
        cancel_jobs(fetch.uuid)

        {:ok, ended} =
          write(fetch, %{
            status: "cancelled",
            finished_at: now(),
            progress: Map.put(fetch.progress || %{}, "phase", "cancelled")
          })

        {:ok, ended}

      _ended ->
        {:error, :ended}
    end
  end

  # Jobs that have not started yet are cancelled in Oban; a running one is told over
  # the control topic, so it finishes storing the file in hand and ends its tool.
  defp cancel_jobs(fetch_uuid) do
    Oban.Job
    |> where([j], j.worker in ^[inspect(ProbeJob), inspect(FetchJob)])
    |> where([j], j.state in ["available", "scheduled", "retryable"])
    |> where([j], fragment("?->>'fetch' = ?", j.args, ^to_string(fetch_uuid)))
    |> Oban.cancel_all_jobs()

    :ok
  rescue
    error -> Logger.warning("[Fetches] cancelling jobs failed: #{Exception.message(error)}")
  end

  @doc """
  Runs an ended fetch again (`"failed"`, `"cancelled"`, or `"done"` with failures), for
  what it has not saved yet. A look that failed is looked at again.
  """
  @spec retry(scope(), String.t()) :: {:ok, Fetch.t()} | {:error, atom()}
  def retry(scope, uuid) do
    with %Fetch{} = fetch <- get(scope, uuid) || {:error, :not_found},
         :ok <- may_add(scope, fetch.library_uuid),
         :ok <- available() do
      again(fetch)
    end
  end

  defp again(%Fetch{status: "unavailable"} = fetch),
    do: requeue(fetch, "probing", ProbeJob, %{info: %{}, progress: %{}})

  defp again(%Fetch{status: status} = fetch) when status in ["failed", "cancelled", "done"] do
    case missing_items(fetch) do
      [] ->
        {:error, :nothing_missing}

      missing ->
        requeue(fetch, "queued", FetchJob, %{
          choices: Map.put(fetch.choices || %{}, "items", missing),
          progress: %{"phase" => "waiting", "items" => length(missing)},
          finished_at: nil,
          started_at: nil,
          dismissed_at: nil
        })
    end
  end

  defp again(_fetch), do: {:error, :not_ended}

  defp requeue(fetch, status, worker, attrs) do
    repo().transaction(fn ->
      {:ok, fetch} =
        write(fetch, Map.merge(attrs, %{status: status, error_code: nil, error: nil}),
          broadcast: false
        )

      {:ok, _} = Oban.insert(worker.new(%{"fetch" => fetch.uuid}))
      fetch
    end)
    |> tap(fn
      {:ok, fetch} -> broadcast(fetch)
      _ -> :ok
    end)
  end

  @doc "The picked entries of `fetch` that have no stored (or already present) file yet."
  @spec missing_items(Fetch.t()) :: [integer()]
  def missing_items(%Fetch{} = fetch) do
    done =
      from(i in Item,
        where: i.fetch_uuid == ^fetch.uuid and i.status in ["stored", "duplicate", "elsewhere"],
        select: i.position
      )
      |> repo().all()
      |> MapSet.new()

    picked =
      (fetch.choices || %{})["items"] ||
        for(%{"index" => i} <- fetch.info["entries"] || [], do: i)

    Enum.reject(picked, &MapSet.member?(done, &1))
  end

  @doc "Hides an ended fetch from the person's cards and list."
  @spec dismiss(scope(), String.t()) :: {:ok, Fetch.t()} | {:error, atom()}
  def dismiss(scope, uuid) do
    case get(scope, uuid) do
      nil ->
        {:error, :not_found}

      %Fetch{status: status} = fetch when status in ["done", "failed", "cancelled"] ->
        write(fetch, %{dismissed_at: now()})

      _ ->
        {:error, :not_ended}
    end
  end

  # ── Reading ───────────────────────────────────────────────────────────

  @doc "A fetch of the person of `scope`, or nil."
  @spec get(scope(), String.t()) :: Fetch.t() | nil
  def get(scope, uuid) do
    with user_uuid when is_binary(user_uuid) <- Scope.user_uuid(scope),
         {:ok, uuid} <- Ecto.UUID.cast(uuid) do
      repo().one(from(f in Fetch, where: f.uuid == ^uuid and f.user_uuid == ^user_uuid))
    else
      _ -> nil
    end
  end

  @doc false
  def get!(uuid), do: repo().get!(Fetch, uuid)

  @doc false
  def get_any(uuid) do
    case Ecto.UUID.cast(uuid) do
      {:ok, uuid} -> repo().get(Fetch, uuid)
      _ -> nil
    end
  end

  @doc "The person's fetches, newest first, dismissed ones left out (`limit`, default 100)."
  @spec list(scope(), keyword()) :: [Fetch.t()]
  def list(scope, opts \\ []) do
    case Scope.user_uuid(scope) do
      nil ->
        []

      user_uuid ->
        from(f in Fetch,
          where: f.user_uuid == ^user_uuid and is_nil(f.dismissed_at),
          order_by: [desc: f.inserted_at],
          limit: ^Keyword.get(opts, :limit, 100)
        )
        |> repo().all()
    end
  end

  @doc """
  The cards of a library for the person: their fetches into it that are not dismissed,
  leaving out ones that ended more than a day ago. Oldest first.
  """
  @spec for_library(scope(), String.t()) :: [Fetch.t()]
  def for_library(scope, library_uuid) do
    with user_uuid when is_binary(user_uuid) <- Scope.user_uuid(scope),
         {:ok, library_uuid} <- Ecto.UUID.cast(library_uuid) do
      since = NaiveDateTime.add(now(), -@card_hours * 3600)

      from(f in Fetch,
        where: f.user_uuid == ^user_uuid and f.library_uuid == ^library_uuid,
        where: is_nil(f.dismissed_at),
        where: f.status not in ["done", "failed", "cancelled"] or f.finished_at > ^since,
        order_by: [asc: f.inserted_at]
      )
      |> repo().all()
    else
      _ -> []
    end
  end

  @doc "Whether `fetch` belongs on the cards of its library now (see `for_library/2`)."
  @spec on_cards?(Fetch.t()) :: boolean()
  def on_cards?(%Fetch{dismissed_at: nil, status: status, finished_at: finished}) do
    status not in ["done", "failed", "cancelled"] or
      (finished != nil and NaiveDateTime.diff(now(), finished) < @card_hours * 3600)
  end

  def on_cards?(_fetch), do: false

  @doc "How many of the person's fetches go before a queued one (0 when it is next)."
  @spec waiting_before(Fetch.t()) :: non_neg_integer()
  def waiting_before(%Fetch{status: "queued"} = fetch) do
    repo().aggregate(
      from(f in Fetch,
        where: f.user_uuid == ^fetch.user_uuid and f.uuid != ^fetch.uuid,
        where:
          f.status == "running" or (f.status == "queued" and f.inserted_at < ^fetch.inserted_at)
      ),
      :count
    )
  end

  def waiting_before(_fetch), do: 0

  @doc "The items a fetch brought in, in order."
  @spec items(Fetch.t()) :: [Item.t()]
  def items(%Fetch{uuid: uuid}) do
    repo().all(
      from(i in Item,
        where: i.fetch_uuid == ^uuid,
        order_by: [asc: i.position, asc: i.inserted_at]
      )
    )
  end

  @doc """
  Where a stored file came from, for the viewer, or nil when it was not fetched:
  `%{url, site, author, title, posted_at}`. The source of a file is part of the file
  (credit to its author), so anyone who may see the file may see this.
  """
  @spec source_for(String.t() | nil) :: map() | nil
  def source_for(nil), do: nil

  def source_for(file_uuid) do
    with {:ok, file_uuid} <- Ecto.UUID.cast(file_uuid),
         %Item{} = item <-
           repo().one(
             from(i in Item,
               where: i.file_uuid == ^file_uuid,
               order_by: [asc: i.inserted_at],
               limit: 1
             )
           ) do
      %{
        url: item.source_url,
        site: Link.site(item.source_url || ""),
        author: item.author,
        title: item.title,
        posted_at: item.posted_at
      }
    else
      _ -> nil
    end
  rescue
    # A host without this package's tables yet (its chain not run) shows no source.
    _ -> nil
  end

  @doc """
  The rows core's media viewer adds to a file's details
  (`config :phoenix_kit, :media_file_info, [{PhoenixKitPhotos.Fetches, :file_info}]`):
  for a file fetched from a link, where it came from (`Source: flickr.com · by NASA HQ`,
  linking to the post) and when it was posted. Nothing for any other file.
  """
  @spec file_info(map()) :: [map()]
  def file_info(%{uuid: uuid}) do
    case source_for(uuid) do
      %{url: url} = source when is_binary(url) ->
        text =
          [source.site, source.author && gettext("by %{author}", author: source.author)]
          |> Enum.reject(&is_nil/1)
          |> Enum.join(" · ")

        posted =
          case source.posted_at do
            %NaiveDateTime{} = at ->
              [%{label: gettext("Posted:"), text: Calendar.strftime(at, "%-d %b %Y")}]

            _ ->
              []
          end

        [%{label: gettext("Source:"), text: text, href: url} | posted]

      _ ->
        []
    end
  end

  def file_info(_file), do: []

  @doc """
  Merges `data` into the fetch's `origin_data`: what the place it came from keeps to
  answer there (Fotki's bot: the message that asked for the confirmation).
  """
  @spec put_origin_data(Fetch.t(), map()) :: {:ok, Fetch.t()} | {:error, term()}
  def put_origin_data(%Fetch{} = fetch, data) when is_map(data) do
    write(fetch, %{origin_data: Map.merge(fetch.origin_data || %{}, data)}, broadcast: false)
  end

  @doc "What a person is told about a fetch that could not be done."
  @spec error_message(Fetch.t()) :: String.t()
  def error_message(%Fetch{error_code: code, site: site}), do: Errors.message(code, site)

  # ── Housekeeping ──────────────────────────────────────────────────────

  @doc """
  Forgets fetches never confirmed for a day, ends as `"failed"` any `"running"` fetch
  that has been silent well past the stall limit (its job died with its node and was
  not brought back), and deletes work folders a day old whose fetch is not on its way.
  Called by `PhoenixKitPhotos.StagingSweepJob`.
  """
  @spec sweep() :: :ok
  def sweep do
    sweep_rows()
    sweep_folders()
    :ok
  end

  defp sweep_folders do
    root = Config.work_dir()
    old = System.os_time(:second) - @open_for_hours * 3600

    with {:ok, names} <- File.ls(root) do
      active =
        from(f in Fetch, where: f.status in ["probing", "queued", "running"], select: f.uuid)
        |> repo().all()
        |> MapSet.new(&to_string/1)

      for name <- names,
          not MapSet.member?(active, name),
          path = Path.join(root, name),
          {:ok, %{mtime: mtime}} <- [File.stat(path, time: :posix)],
          mtime < old do
        Runner.kill_leftover(path)
        File.rm_rf(path)
      end
    end

    :ok
  rescue
    error -> Logger.warning("[Fetches] sweeping folders failed: #{Exception.message(error)}")
  end

  defp sweep_rows do
    old = NaiveDateTime.add(now(), -@open_for_hours * 3600)

    repo().delete_all(
      from(f in Fetch,
        where: f.status in ["probing", "ready", "unavailable"] and f.updated_at < ^old
      )
    )

    dead = NaiveDateTime.add(now(), -(Config.get(:stall_s) + @dead_grace_s))

    from(f in Fetch, where: f.status == "running" and f.updated_at < ^dead)
    |> repo().all()
    |> Enum.each(fn fetch ->
      Logger.warning("[Fetches] fetch #{fetch.uuid} lost its job; marking it failed")
      write(fetch, %{status: "failed", error_code: "stalled", finished_at: now()})
    end)

    :ok
  rescue
    error -> Logger.warning("[Fetches] sweep failed: #{Exception.message(error)}")
  end

  # ── For the jobs ──────────────────────────────────────────────────────

  @doc false
  # Writes `attrs` and tells the person's pages (unless `broadcast: false`).
  def write(%Fetch{} = fetch, attrs, opts \\ []) do
    attrs = Map.put(attrs, :updated_at, now())

    fetch
    |> Ecto.Changeset.change(attrs)
    |> repo().update()
    |> tap(fn
      {:ok, fetch} -> if Keyword.get(opts, :broadcast, true), do: broadcast(fetch)
      _ -> :ok
    end)
  end

  @doc false
  # Writes `progress` alone and tells the pages with the row as it now is: a job's own
  # copy may be stale (the person cancelled meanwhile), and must not undo that.
  def put_progress(%Fetch{uuid: uuid} = fetch, progress) do
    case repo().update_all(from(f in Fetch, where: f.uuid == ^uuid, select: f),
           set: [progress: progress, updated_at: now()]
         ) do
      {1, [fresh]} ->
        broadcast(fresh)
        {:ok, fresh}

      _ ->
        {:ok, fetch}
    end
  end

  @doc false
  def broadcast(%Fetch{} = fetch) do
    Manager.broadcast(topic(fetch.user_uuid), {:phoenix_kit_photos_fetch, fetch})
  end

  @doc false
  def now, do: NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

  @doc false
  def repo, do: PhoenixKit.RepoHelper.repo()
end
