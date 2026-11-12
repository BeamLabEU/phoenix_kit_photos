defmodule PhoenixKitPhotos.Fetches.YtDlp do
  @moduledoc """
  yt-dlp's command lines and what its output means. Pure: `PhoenixKitPhotos.Fetches.Runner`
  runs the commands.

  ## Looking first

  `probe_args/2` asks for one JSON document (`-J`) about the link, a playlist's entries
  listed flat (`--flat-playlist`, without opening each one), capped one past the limit
  so the dialog can say there is more. `probe_info/2` turns it into the fetch's `info`.

  ## Fetching

  `fetch_args/3` downloads with progress as machine lines on stdout:

    * `PKF_ITEM <index> <id>` before each video,
    * `PKF_DL <json>` yt-dlp's progress dict (`downloaded_bytes`, `total_bytes` or
      `total_bytes_estimate`, `speed`, `eta`, `status`),
    * `PKF_PP <status> <postprocessor>` while joining video and audio (`Merger`),
    * `PKF_FILE <json>` a finished file: its path and what is known about it.

  `parse_line/1` reads them. Quality: `"default"` sorts for 1080p at most, `"best"`
  takes the best there is; either way video and audio are joined into an mp4 (core makes
  the browser's H.264 copy, so the codec inside is kept). `--no-playlist` makes a
  video link that also names a playlist mean the video.
  """

  alias PhoenixKitPhotos.Fetches.{Config, Meta}

  @default_height 1080

  @doc "The arguments of the look before fetching."
  @spec probe_args(String.t(), keyword()) :: [String.t()]
  def probe_args(url, opts) do
    max = Keyword.fetch!(opts, :max_items)

    common(opts) ++
      ["-J", "--flat-playlist", "--playlist-items", "1:#{max + 1}", "--", url]
  end

  @doc """
  The arguments that download `url` into `dir`. `opts`: `:quality` (`"default"` or
  `"best"`), `:items` (playlist positions, or nil for all up to `:max_items`), and what
  `probe_args/2` takes.
  """
  @spec fetch_args(String.t(), Path.t(), keyword()) :: [String.t()]
  def fetch_args(url, dir, opts) do
    max = Keyword.fetch!(opts, :max_items)

    items =
      case Keyword.get(opts, :items) do
        [_ | _] = picked -> Enum.map_join(picked, ",", &to_string/1)
        _ -> "1:#{max}"
      end

    sort =
      case Keyword.get(opts, :quality) do
        "best" -> []
        _ -> ["-S", "res:#{@default_height}"]
      end

    common(opts) ++
      [
        "--newline",
        "--progress",
        "--progress-template",
        "download:PKF_DL %(progress)j",
        "--progress-template",
        "postprocess:PKF_PP %(progress.status)s %(progress.postprocessor)s",
        "--print",
        "before_dl:PKF_ITEM %(playlist_index|0)s %(id)j",
        "--print",
        "after_move:PKF_FILE %(.{filepath,id,title,fulltitle,uploader,channel,creator,timestamp,release_timestamp,upload_date,webpage_url,playlist_index,ext})j",
        "--playlist-items",
        items,
        "-f",
        "bv*+ba/b"
      ] ++
      sort ++
      [
        "--merge-output-format",
        "mp4",
        "--max-filesize",
        to_string(Config.get(:max_file_bytes)),
        "--match-filter",
        "!is_live & duration<=?#{Config.get(:max_duration_s)}",
        "--restrict-filenames",
        "--no-mtime",
        "-P",
        dir,
        "-o",
        "%(playlist_index|0)s-%(id)s.%(ext)s",
        "--",
        url
      ]
  end

  defp common(opts) do
    ["--proxy", Keyword.fetch!(opts, :proxy), "--ignore-config", "--no-color", "--no-playlist"] ++
      js_runtimes() ++ cookies(opts)
  end

  defp js_runtimes do
    case Config.get(:js_runtimes) do
      runtime when is_binary(runtime) and runtime != "" -> ["--js-runtimes", runtime]
      _ -> []
    end
  end

  defp cookies(opts) do
    case Keyword.get(opts, :cookies) do
      path when is_binary(path) -> ["--cookies", path]
      _ -> []
    end
  end

  @doc """
  The fetch's `info` from yt-dlp's `-J` document: what the dialog shows and what the
  limits are checked against. A playlist is a `"collection"` of its entries (at most
  `max_items`, `"more"` when it has more); anything else is one video.
  """
  @spec probe_info(map(), pos_integer()) :: map()
  def probe_info(%{"_type" => "playlist"} = doc, max_items) do
    entries = Enum.filter(doc["entries"] || [], &is_map/1)

    listed =
      entries
      |> Enum.take(max_items)
      |> Enum.with_index(1)
      |> Enum.map(fn {entry, index} ->
        %{
          "index" => entry["playlist_index"] || index,
          "title" => Meta.title(entry),
          "thumbnail" => thumbnail(entry),
          "duration" => duration(entry),
          "kind" => "video"
        }
      end)

    %{
      "kind" => "collection",
      "title" => Meta.title(doc),
      "author" => Meta.author(doc),
      "count" => doc["playlist_count"] || length(entries),
      "more" => length(entries) > max_items,
      "entries" => listed,
      "video" => true
    }
  end

  def probe_info(doc, _max_items) when is_map(doc) do
    duration = duration(doc)
    {default_size, default_height} = estimate(doc, @default_height, duration)
    {best_size, best_height} = estimate(doc, nil, duration)

    %{
      "kind" => "single",
      "title" => Meta.title(doc),
      "author" => Meta.author(doc),
      "posted_at" => iso(Meta.posted_at(doc)),
      "thumbnail" => thumbnail(doc),
      "duration" => duration,
      "is_live" => doc["is_live"] == true,
      "video" => true,
      "count" => 1,
      "entries" => [
        %{
          "index" => 1,
          "title" => Meta.title(doc),
          "thumbnail" => thumbnail(doc),
          "kind" => "video"
        }
      ],
      "sizes" => %{"default" => default_size, "best" => best_size},
      "heights" => %{"default" => default_height, "best" => best_height}
    }
  end

  # The size of what a quality would download: the best video stream no taller than
  # `max_height` (any height when nil) and, when that stream has no sound, the best
  # audio stream. From each format's `filesize`, else `filesize_approx`, else its bitrate
  # over the duration. `{nil, nil}` when the formats say too little.
  defp estimate(doc, max_height, duration) do
    formats = Enum.filter(doc["formats"] || [], &is_map/1)

    case best_video(formats, max_height) do
      nil -> {size(doc, duration), nil}
      video -> {video_size(video, best_audio(formats), duration), video["height"]}
    end
  end

  defp best_video(formats, max_height) do
    formats
    |> Enum.filter(&(has?(&1, "vcodec") and fits?(&1["height"], max_height)))
    |> Enum.max_by(&{&1["height"], &1["tbr"] || 0}, fn -> nil end)
  end

  defp fits?(height, _max) when not is_integer(height), do: false
  defp fits?(_height, nil), do: true
  defp fits?(height, max), do: height <= max

  defp best_audio(formats) do
    formats
    |> Enum.filter(&(has?(&1, "acodec") and not has?(&1, "vcodec")))
    |> Enum.max_by(&(&1["abr"] || &1["tbr"] || 0), fn -> nil end)
  end

  # A video stream with its own sound is the whole download; one without needs the audio.
  defp video_size(video, audio, duration) do
    case size(video, duration) do
      nil -> nil
      bytes -> if has?(video, "acodec"), do: bytes, else: bytes + (size(audio, duration) || 0)
    end
  end

  defp has?(format, key) do
    case format[key] do
      codec when is_binary(codec) -> codec != "none"
      _ -> false
    end
  end

  defp size(nil, _duration), do: nil

  defp size(format, duration) do
    cond do
      is_integer(format["filesize"]) -> format["filesize"]
      is_number(format["filesize_approx"]) -> trunc(format["filesize_approx"])
      is_number(format["tbr"]) and is_number(duration) -> trunc(format["tbr"] * 125 * duration)
      true -> nil
    end
  end

  defp duration(%{"duration" => duration}) when is_number(duration), do: round(duration)
  defp duration(_doc), do: nil

  defp thumbnail(%{"thumbnail" => url}) when is_binary(url), do: url

  defp thumbnail(%{"thumbnails" => [_ | _] = thumbnails}) do
    thumbnails |> Enum.filter(&is_binary(&1["url"])) |> List.last() |> then(&(&1 && &1["url"]))
  end

  defp thumbnail(_doc), do: nil

  defp iso(nil), do: nil
  defp iso(%NaiveDateTime{} = dt), do: NaiveDateTime.to_iso8601(dt)

  @doc """
  One line of a fetch's output:

    * `{:item, index}` — a video starts (1 for a single video),
    * `{:progress, %{bytes, total, speed, eta, finished}}`,
    * `{:postprocess, status, name}`,
    * `{:file, path, meta}` — a file is done (`meta` is yt-dlp's dict),
    * `:other` — anything else.
  """
  @spec parse_line(String.t()) ::
          {:item, pos_integer()}
          | {:progress, map()}
          | {:postprocess, String.t(), String.t()}
          | {:file, Path.t(), map()}
          | :other
  def parse_line("PKF_ITEM " <> rest) do
    case String.split(rest, " ", parts: 2) do
      [index | _] ->
        case Integer.parse(index) do
          {n, ""} when n > 0 -> {:item, n}
          _ -> {:item, 1}
        end

      _ ->
        :other
    end
  end

  def parse_line("PKF_DL " <> json) do
    case Jason.decode(json) do
      {:ok, %{} = p} ->
        {:progress,
         %{
           bytes: int(p["downloaded_bytes"]),
           total: int(p["total_bytes"]) || int(p["total_bytes_estimate"]),
           speed: int(p["speed"]),
           eta: int(p["eta"]),
           finished: p["status"] == "finished"
         }}

      _ ->
        :other
    end
  end

  def parse_line("PKF_PP " <> rest) do
    case String.split(rest, " ", parts: 2) do
      [status, name] -> {:postprocess, status, String.trim(name)}
      _ -> :other
    end
  end

  def parse_line("PKF_FILE " <> json) do
    case Jason.decode(json) do
      {:ok, %{"filepath" => path} = meta} when is_binary(path) -> {:file, path, meta}
      _ -> :other
    end
  end

  def parse_line(_line), do: :other

  defp int(n) when is_integer(n), do: n
  defp int(n) when is_float(n), do: trunc(n)
  defp int(_n), do: nil
end
