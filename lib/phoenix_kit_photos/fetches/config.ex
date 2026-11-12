defmodule PhoenixKitPhotos.Fetches.Config do
  @moduledoc """
  Fetching from a link: whether it is on, the tools, the proxy and the limits.

      config :phoenix_kit_photos, PhoenixKitPhotos.Fetches,
        enabled: true,
        proxy: System.get_env("FETCH_PROXY"),
        max_file_bytes: 1_073_741_824,
        max_duration_s: 3_600,
        max_items: 50

  Every key is optional; the defaults are below. Fetching is **off** unless `enabled:
  true` is set, and even then it refuses to run (`available/0`) without a proxy and the
  tools on `PATH`.

  ## The proxy is not optional

  A pasted URL is chosen by a person and fetched by the server, so without a guard it
  can reach the server's own network: `localhost`, the database, the cloud's metadata
  address. Both tools fetch such addresses happily. Every request they make goes
  through `:proxy`, an egress proxy that refuses private and internal addresses after
  DNS and on every redirect (smokescreen in Fotki's image). Nothing in this package
  ever hands a person's URL to anything else: ffmpeg gets the proxy from yt-dlp, and
  stored files are read from disk after a proxied tool wrote them.

  ## Keys

    * `:enabled` — `false` by default.
    * `:proxy` — `http://host:port` of the egress proxy. Required.
    * `:yt_dlp`, `:gallery_dl` — the executables, by name or path (`"yt-dlp"`,
      `"gallery-dl"`).
    * `:js_runtimes` — passed to yt-dlp's `--js-runtimes` (YouTube needs one; `"node"`
      by default, `nil` to leave yt-dlp's own choice).
    * `:max_file_bytes` — the largest file fetched (1 GiB).
    * `:max_duration_s` — the longest video fetched (1 hour).
    * `:max_items` — the most files one fetch brings in (50).
    * `:per_user` — fetches that run at once for one person (1); the rest wait.
    * `:stall_s` — a fetch that says nothing for this long is stopped (600).
    * `:probe_timeout_s` — the look before fetching gives up after this (90).
    * `:job_timeout_ms` — the longest a fetch may run (55 minutes: keep it below the
      host's Oban Lifeline `rescue_after`, or a long fetch is started a second time).
    * `:work_dir` — where files are downloaded before they are stored.
    * `:on_finished` — `{module, function}`, called with every fetch that ended
      (`PhoenixKitPhotos.Fetches.Notify`).
    * `:on_looked` — `{module, function}`, called with a fetch whose look ended.
    * `:link` — `{module, function}`, called with a fetch, giving the path its bell
      notification links to (its library's page).
  """

  @app :phoenix_kit_photos
  @key PhoenixKitPhotos.Fetches

  @defaults [
    enabled: false,
    proxy: nil,
    yt_dlp: "yt-dlp",
    gallery_dl: "gallery-dl",
    js_runtimes: "node",
    max_file_bytes: 1_073_741_824,
    max_duration_s: 3_600,
    max_items: 50,
    per_user: 1,
    stall_s: 600,
    probe_timeout_s: 90,
    job_timeout_ms: 55 * 60 * 1000,
    work_dir: nil,
    on_finished: nil,
    on_looked: nil,
    link: nil
  ]

  @doc "One setting, with its default."
  @spec get(atom()) :: term()
  def get(key) when is_atom(key) do
    @app
    |> Application.get_env(@key, [])
    |> Keyword.get(key, Keyword.fetch!(@defaults, key))
  end

  @doc "Whether the host switched fetching on (not whether it can run: `available/0`)."
  @spec enabled?() :: boolean()
  def enabled?, do: get(:enabled) == true

  @doc """
  `:ok` when a fetch can run here, else why not: `:disabled`, `:no_proxy`, or
  `{:missing, tool}` for a tool that is not on `PATH`.
  """
  @spec available() :: :ok | {:error, :disabled | :no_proxy | {:missing, String.t()}}
  def available do
    cond do
      not enabled?() -> {:error, :disabled}
      proxy() == nil -> {:error, :no_proxy}
      executable(:yt_dlp) == nil -> {:error, {:missing, get(:yt_dlp)}}
      executable(:gallery_dl) == nil -> {:error, {:missing, get(:gallery_dl)}}
      true -> :ok
    end
  end

  @doc "Whether fetching is on and can run (`available/0` is `:ok`)."
  @spec available?() :: boolean()
  def available?, do: available() == :ok

  @doc "The proxy URL, or nil when none (or an empty one) is set."
  @spec proxy() :: String.t() | nil
  def proxy do
    case get(:proxy) do
      proxy when is_binary(proxy) and proxy != "" -> proxy
      _ -> nil
    end
  end

  @doc "The full path of a tool (`:yt_dlp` or `:gallery_dl`), or nil when it is not found."
  @spec executable(:yt_dlp | :gallery_dl) :: String.t() | nil
  def executable(tool) when tool in [:yt_dlp, :gallery_dl] do
    name = get(tool)

    if String.contains?(name, "/"),
      do: if(File.regular?(name), do: name),
      else: System.find_executable(name)
  end

  @doc "Where a fetch's files are downloaded: one folder per fetch under this."
  @spec work_dir() :: Path.t()
  def work_dir do
    get(:work_dir) || Path.join(System.tmp_dir!(), "phoenix_kit_photos_fetches")
  end

  @doc "The folder of one fetch."
  @spec work_dir(String.t()) :: Path.t()
  def work_dir(fetch_uuid), do: Path.join(work_dir(), to_string(fetch_uuid))
end
