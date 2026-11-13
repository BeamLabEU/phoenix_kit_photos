defmodule PhoenixKitPhotos.Fetches.ProbeJob do
  @moduledoc """
  The look before fetching: what a link holds, so the person can see it and choose
  before anything is downloaded. Runs in the `photo_fetches` queue, which the host
  declares (`photo_fetches: 3`).

  ## Which tool

  gallery-dl first: it knows photo sites and plain links to a file (`directlink`), and
  says "Unsupported URL" at once, without the network, for a link it has no reader for.
  Then yt-dlp, for video sites and whatever gallery-dl passed. gallery-dl also hands
  some videos on to yt-dlp (`ytdl:` URLs): a link like that goes to yt-dlp whole.

  A person's own login for the site (`SiteLogins`) goes with the look, so a site that
  needs one can be read.

  ## Limits, before anything is downloaded

  A video longer than `:max_duration_s`, or estimated larger than `:max_file_bytes`
  even at 1080p, is `"unavailable"` (`too_long`, `too_big`); a live stream too. A
  collection lists at most `:max_items` entries and says when there are more.
  """

  use Oban.Worker,
    queue: :photo_fetches,
    max_attempts: 2,
    unique: [keys: [:fetch], period: 60, states: [:available, :scheduled, :executing]]

  require Logger

  alias PhoenixKitPhotos.Fetches

  alias PhoenixKitPhotos.Fetches.{
    Config,
    Errors,
    Fetch,
    GalleryDl,
    Notify,
    Runner,
    SiteLogins,
    YtDlp
  }

  @impl Oban.Worker
  def timeout(_job), do: :timer.seconds(Config.get(:probe_timeout_s) * 2 + 30)

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"fetch" => uuid}}) do
    case Fetches.get_any(uuid) do
      %Fetch{status: "probing"} = fetch -> probe(fetch)
      _gone_or_moved_on -> :ok
    end
  end

  @doc false
  def probe(%Fetch{} = fetch) do
    dir = Path.join(Config.work_dir(fetch.uuid), "probe")
    File.rm_rf(dir)
    File.mkdir_p!(dir)

    try do
      opts = [
        proxy: Config.proxy(),
        max_items: Config.get(:max_items),
        cookies: SiteLogins.cookie_file(to_string(fetch.user_uuid), fetch.url, dir)
      ]

      result =
        case look(:gallery_dl, fetch.url, dir, opts) do
          {:ok, %{"category" => "directlink"} = info} ->
            check_direct(fetch.url, dir, opts, info)

          {:ok, info} ->
            {:ok, "gallery_dl", info}

          {:next, _why} ->
            with({:ok, info} <- look(:yt_dlp, fetch.url, dir, opts), do: {:ok, "yt_dlp", info})

          {:error, code, detail} ->
            {:error, code, detail}
        end

      finish(fetch, result, opts[:cookies] != nil)
    after
      File.rm_rf(dir)
    end
  end

  defp finish(fetch, {:ok, tool, info}, with_login) do
    if with_login, do: SiteLogins.mark(to_string(fetch.user_uuid), fetch.url, :worked)

    case limit(info) do
      :ok ->
        Fetches.write(fetch, %{
          status: "ready",
          tool: tool,
          info: Map.put(info, "previous", previous(fetch))
        })

      {:error, code} ->
        Fetches.write(fetch, %{status: "unavailable", tool: tool, info: info, error_code: code})
    end
    |> looked()
  end

  defp finish(fetch, {:error, code, detail}, with_login) do
    if with_login and code == "needs_login",
      do: SiteLogins.mark(to_string(fetch.user_uuid), fetch.url, :failed)

    Logger.info("[Fetches] look at #{fetch.site} found nothing to fetch (#{code}): #{detail}")

    fetch
    |> Fetches.write(%{status: "unavailable", error_code: code, error: detail})
    |> looked()
  end

  defp looked({:ok, fetch}), do: Notify.looked(fetch)
  defp looked(_), do: :ok

  # gallery-dl reads a plain link to a file from its address alone, without a request, so
  # the look would say "ready" for anything ending in .jpg. yt-dlp makes the request
  # (through the proxy): a video (it has a duration) is yt-dlp's; an address the proxy
  # refuses, or one that is not there, is said now; an image stays gallery-dl's.
  defp check_direct(url, dir, opts, info) do
    case look(:yt_dlp, url, dir, opts) do
      {:ok, %{"duration" => seconds} = video} when is_integer(seconds) ->
        {:ok, "yt_dlp", video}

      {:error, code, detail} when code in ["address", "not_found", "blocked", "needs_login"] ->
        {:error, code, detail}

      _ ->
        {:ok, "gallery_dl", info}
    end
  end

  # `{:ok, info}`, `{:next, why}` (try the other tool), or `{:error, code, detail}`.
  defp look(tool, url, dir, opts) do
    exe = Config.executable(tool)

    args =
      if tool == :yt_dlp, do: YtDlp.probe_args(url, opts), else: GalleryDl.probe_args(url, opts)

    case Runner.run(exe, args, dir: dir, timeout_ms: Config.get(:probe_timeout_s) * 1000) do
      {:error, :timeout} ->
        {:error, "timeout", nil}

      {:ok, status, stdout} ->
        stderr = Runner.stderr_tail(dir)
        read(tool, status, stdout, stderr, opts)
    end
  end

  defp read(:gallery_dl, status, stdout, stderr, opts) do
    with {:ok, messages} when is_list(messages) <- Jason.decode(stdout),
         %{} = info <- GalleryDl.probe_info(messages, opts[:max_items]) do
      {:ok, info}
    else
      {:delegate, :yt_dlp} ->
        {:next, :delegate}

      _ ->
        reported = GalleryDl.reported_error(stdout)
        code = gallery_dl_code(reported, stderr, opts[:cookies] != nil)

        cond do
          code == "unsupported" ->
            {:next, :unsupported}

          code in ["needs_login", "blocked", "address", "not_found"] ->
            {:error, code, reported || Errors.last_error_line(stderr)}

          # gallery-dl read the page and found no files: perhaps a video page it only links to.
          status == 0 ->
            {:next, :nothing}

          true ->
            {:next, :failed}
        end
    end
  end

  defp read(:yt_dlp, _status, stdout, stderr, opts) do
    case Jason.decode(stdout) do
      {:ok, %{} = doc} ->
        {:ok, YtDlp.probe_info(doc, opts[:max_items])}

      _ ->
        {:error, Errors.classify(stderr), Errors.last_error_line(stderr)}
    end
  end

  # Why gallery-dl found nothing: from its stderr, and from the error its extractor raised,
  # which `-J` puts inside the JSON (`reported`), never on stderr. Without reading that, the
  # look went on to yt-dlp and told a person yt-dlp's "No video could be found in this
  # tweet" for a photo post that needs a login. A tweet a guest may not see says only
  # "Unavailable": a login is what shows it, unless the look already had the person's login
  # (then it is not there for them), or the reason says it is gone.
  defp gallery_dl_code(reported, stderr, with_login) do
    text = Enum.join(List.wrap(reported) ++ [stderr || ""], "\n")

    case Errors.classify(text) do
      "failed" when is_binary(reported) ->
        cond do
          not (reported =~ ~r/unavailable/i) -> "failed"
          with_login or reported =~ ~r/suspend|delet|removed|tombstone/i -> "not_found"
          true -> "needs_login"
        end

      code ->
        code
    end
  end

  defp limit(%{"is_live" => true}), do: {:error, "live"}

  defp limit(%{"kind" => "single"} = info) do
    duration = info["duration"]
    size = get_in(info, ["sizes", "default"])

    cond do
      is_integer(duration) and duration > Config.get(:max_duration_s) -> {:error, "too_long"}
      is_integer(size) and size > Config.get(:max_file_bytes) -> {:error, "too_big"}
      true -> :ok
    end
  end

  defp limit(%{"entries" => [_ | _]}), do: :ok
  defp limit(_info), do: {:error, "nothing"}

  # The last time this person fetched the same link into the same library, if they did.
  defp previous(fetch) do
    import Ecto.Query

    from(f in Fetch,
      where:
        f.user_uuid == ^fetch.user_uuid and f.library_uuid == ^fetch.library_uuid and
          f.url == ^fetch.url and f.uuid != ^fetch.uuid and f.status == "done",
      order_by: [desc: f.finished_at],
      limit: 1,
      select: f.finished_at
    )
    |> Fetches.repo().one()
    |> case do
      nil -> nil
      at -> NaiveDateTime.to_iso8601(at)
    end
  end
end
