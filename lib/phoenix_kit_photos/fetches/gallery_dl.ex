defmodule PhoenixKitPhotos.Fetches.GalleryDl do
  @moduledoc """
  gallery-dl's command lines and what its output means. Pure:
  `PhoenixKitPhotos.Fetches.Runner` runs the commands.

  gallery-dl reads photo sites (Flickr, Pinterest, DeviantArt, ArtStation, Bluesky,
  Wikimedia Commons…, and with a person's cookies Instagram and X) and plain links to
  an image or a video file (its `directlink` reader).

  ## Looking first

  `probe_args/2` asks for the resolved JSON (`-J`): a list of messages, `[2, meta]` for
  a post or album and `[3, url, meta]` for each file, the files capped one past the
  limit. `probe_info/2` turns it into the fetch's `info`; each file's gallery-dl
  `filename` is kept with it as its `key`.

  ## Which files: by name where names are unique, else by number

  A link that expands into other pages (a user's boards, a profile's posts) numbers
  files **per page** under `--range`, so "the third file" of the look and of the fetch
  can differ. So when every file of the look has a `filename` of its own, the fetch
  walks the same way as the look (the same `--range`) and keeps the chosen files by name
  (`--filter`). Where names repeat (Wikimedia lists every version of a file under one
  name) the fetch picks by number (`--range 1,3`), which holds for such flat pages.

  The names come from a third-party site and the filter is a Python expression, so each
  name goes in as a JSON string: a JSON string is also a valid Python string literal and
  cannot end the expression early.

  ## Fetching

  `fetch_args/3` prints `PKF_ITEM <category>` before each file and `PKF_FILE <json path>`
  after it, and writes each file's metadata next to it (`<file>.json`, read by
  `sidecar/1`). gallery-dl reports no bytes in a form meant for machines, so a fetch
  through it counts files.
  """

  alias PhoenixKitPhotos.Fetches.{Config, Meta}

  @video_extensions ~w(mp4 webm mov m4v mkv 3gp)

  @doc "The arguments of the look before fetching."
  @spec probe_args(String.t(), keyword()) :: [String.t()]
  def probe_args(url, opts) do
    max = Keyword.fetch!(opts, :max_items)
    common(opts) ++ ["-J", "--range", "1-#{max + 1}", "--", url]
  end

  @doc """
  The arguments that download `url` into `dir`. `opts`: `:keys` (the `filename`s of the
  files chosen, when every file of the look has a name of its own) or else `:items`
  (their numbers), and what `probe_args/2` takes.
  """
  @spec fetch_args(String.t(), Path.t(), keyword()) :: [String.t()]
  def fetch_args(url, dir, opts) do
    max = Keyword.fetch!(opts, :max_items)

    range =
      case {Keyword.get(opts, :keys), Keyword.get(opts, :items)} do
        {[_ | _], _items} -> "1-#{max + 1}"
        {_keys, [_ | _] = items} -> Enum.map_join(items, ",", &to_string/1)
        _ -> "1-#{max}"
      end

    common(opts) ++
      [
        "-D",
        dir,
        "--range",
        range,
        "--no-mtime",
        "--write-metadata",
        "--filesize-max",
        to_string(Config.get(:max_file_bytes)),
        "--Print",
        "prepare:PKF_ITEM {category}",
        "--Print",
        "after:PKF_FILE {_path!j}"
      ] ++ filter(Keyword.get(opts, :keys)) ++ ["--", url]
  end

  defp common(opts) do
    ["--proxy", Keyword.fetch!(opts, :proxy), "--config-ignore"] ++ cookies(opts)
  end

  defp cookies(opts) do
    case Keyword.get(opts, :cookies) do
      path when is_binary(path) -> ["--cookies", path]
      _ -> []
    end
  end

  @doc """
  The `--filter` that keeps the files named in `keys`, or nothing when `keys` is not a
  list of names. See the moduledoc for why each name is JSON.
  """
  @spec filter([String.t()] | nil) :: [String.t()]
  def filter([_ | _] = keys) do
    names = keys |> Enum.filter(&is_binary/1) |> Enum.uniq()

    case names do
      [] ->
        []

      names ->
        ["--filter", "filename in {" <> Enum.map_join(names, ", ", &Jason.encode!/1) <> "}"]
    end
  end

  def filter(_keys), do: []

  @doc """
  The fetch's `info` from gallery-dl's `-J` messages, or `{:delegate, :yt_dlp}` when
  the files are videos gallery-dl can only hand to yt-dlp (`ytdl:` URLs), or
  `{:error, :nothing}` when there are no files.
  """
  @spec probe_info(list(), pos_integer()) :: map() | {:delegate, :yt_dlp} | {:error, :nothing}
  def probe_info(messages, max_items) when is_list(messages) do
    files =
      for [3, url, %{} = meta] <- messages, is_binary(url), do: {url, meta}

    cond do
      files == [] ->
        {:error, :nothing}

      Enum.any?(files, fn {url, _} -> String.starts_with?(url, "ytdl:") end) ->
        {:delegate, :yt_dlp}

      true ->
        info(files, max_items)
    end
  end

  def probe_info(_messages, _max_items), do: {:error, :nothing}

  @doc """
  The error gallery-dl's extractor raised, from its `-J` output (`stdout`, raw or decoded),
  as `"Class: message"`: `-J` reports it as a message `[-1, %{"error", "message"}]` in the
  JSON, not on stderr. `nil` when there is none.
  """
  @spec reported_error(String.t() | list() | nil) :: String.t() | nil
  def reported_error(stdout) when is_binary(stdout) do
    case Jason.decode(stdout) do
      {:ok, messages} -> reported_error(messages)
      _ -> nil
    end
  end

  def reported_error(messages) when is_list(messages) do
    Enum.find_value(messages, fn
      [-1, %{"error" => error} = said] when is_binary(error) ->
        case said["message"] do
          message when is_binary(message) and message != "" -> "#{error}: #{message}"
          _ -> error
        end

      _ ->
        nil
    end)
  end

  def reported_error(_stdout), do: nil

  defp info(files, max_items) do
    entries =
      files
      |> Enum.take(max_items)
      |> Enum.with_index(1)
      |> Enum.map(fn {{url, meta}, index} ->
        kind = kind(meta)

        %{
          "index" => index,
          "key" => meta["filename"],
          "title" => Meta.title(meta),
          "author" => Meta.author(meta),
          "posted_at" => iso(Meta.posted_at(meta)),
          "thumbnail" => if(kind == "image", do: url, else: meta["thumbnail"]),
          "kind" => kind,
          "width" => meta["width"],
          "height" => meta["height"]
        }
      end)

    [{_url, first} | _] = files

    %{
      "kind" => if(length(files) == 1, do: "single", else: "collection"),
      "category" => first["category"],
      "title" => Meta.title(first),
      "author" => Meta.author(first),
      "posted_at" => iso(Meta.posted_at(first)),
      "thumbnail" => List.first(entries)["thumbnail"],
      "count" => min(length(files), max_items),
      "more" => length(files) > max_items,
      "entries" => entries,
      "video" => Enum.any?(entries, &(&1["kind"] == "video"))
    }
  end

  defp kind(meta) do
    ext = meta["extension"] |> to_string() |> String.downcase()
    if ext in @video_extensions, do: "video", else: "image"
  end

  defp iso(nil), do: nil
  defp iso(%NaiveDateTime{} = dt), do: NaiveDateTime.to_iso8601(dt)

  @doc """
  One line of a fetch's output: `{:item, category}` before a file, `{:file, path}` after
  it, `:other` for anything else (gallery-dl also prints each path on its own).
  """
  @spec parse_line(String.t()) :: {:item, String.t()} | {:file, Path.t()} | :other
  def parse_line("PKF_ITEM " <> category), do: {:item, String.trim(category)}

  def parse_line("PKF_FILE " <> json) do
    case Jason.decode(json) do
      {:ok, path} when is_binary(path) -> {:file, path}
      _ -> :other
    end
  end

  def parse_line(_line), do: :other

  @doc "The metadata gallery-dl wrote next to `path` (`--write-metadata`), or `%{}`."
  @spec sidecar(Path.t()) :: map()
  def sidecar(path) do
    with {:ok, json} <- File.read(path <> ".json"),
         {:ok, %{} = meta} <- Jason.decode(json) do
      meta
    else
      _ -> %{}
    end
  end
end
