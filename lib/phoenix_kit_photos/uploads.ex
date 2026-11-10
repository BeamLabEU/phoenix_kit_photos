defmodule PhoenixKitPhotos.Uploads do
  @moduledoc """
  What the photo uploader asks of the server: who may add to a library, which files
  it takes, and storing one finished upload. No LiveView in here; the
  `PhoenixKitPhotos.Components.PhotoUploader` component calls it, and so can anything
  else that has a file on disk (an importer, a script).

  ## Who may

  `can_upload?/2`: to a **user library**, its owner, a manager and a contributor
  (`Libraries.allows?(role, :upload)`, so a viewer may not and a trashed library has
  no one); to a **system library** such as Media, an Owner/Admin and a holder of the
  `media` permission. Anything else, and a visitor who is not signed in, may not.
  The check is made again before and after storage (`store/4`), because what
  the browser says is not what the server decides. If access is lost during
  storage, a newly created row is trashed; a pre-existing duplicate is retained.

  ## What it takes

  Pictures and videos (`accept/0`): JPEG, PNG, GIF, WebP, HEIC/HEIF (an iPhone's),
  AVIF, TIFF, BMP, SVG, camera raw (DNG, CR2, CR3, NEF, ARW, ORF, RW2, RAF, PEF…, when
  the host has given MIME their types: `raw_extensions/0`); MP4, MOV (QuickTime), WebM,
  3GP. A raw file is kept as it is; core develops its previews with libraw
  (`PhoenixKit.Modules.Storage.CameraRaw`). (Every extension has to have a
  known MIME type or LiveView refuses to set the upload up; `.m4v` and `.mkv` have none
  in the MIME table, and phones record `.mov` and `.mp4`.) An SVG can carry a script,
  so core never shows one as a page: it is kept as it is and downloads from its link,
  and its sizes and previews are PNGs drawn from it by librsvg
  (`PhoenixKit.Modules.Storage.SvgRaster`). Not documents: this is a photo library. The size limit is the site's `storage_max_upload_size_mb` setting
  (default 500), the same one the media browser follows.

  ## Storing

  The uploader stores in the background when its page can hear back
  (`PhoenixKitPhotos.StoreUploadJob`): it makes `precheck/4`'s cheap checks, moves the
  file out of LiveView's hands (`PhoenixKitPhotos.UploadStaging`) and the job calls
  `store/4`. Everything else that has a file on disk calls `store/4` directly.

  `store/4` hashes the file from disk in chunks (`PhoenixKit.Utils.FileHash`), so a
  video costs the same memory as a thumbnail, and hands it to
  `PhoenixKit.Modules.Storage.store_file_in_buckets/7`, which keeps it, dedups it and
  queues its renditions. It never raises: the caller is a progress callback.
  """

  use Gettext, backend: PhoenixKitPhotos.Gettext

  require Logger

  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Modules.Storage.{CameraRaw, Libraries, Library, Sniff}
  alias PhoenixKit.Settings
  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKit.Utils.FileHash

  @svg "image/svg+xml"
  @image_extensions ~w(.jpg .jpeg .png .gif .webp .heic .heif .avif .tif .tiff .bmp .svg)
  @video_extensions ~w(.mp4 .mov .webm .3gp)
  @extensions @image_extensions ++ @video_extensions

  @default_max_mb 500
  @max_entries 100
  @default_max_concurrent_uploads 4
  @max_concurrency_choice 8

  @type outcome ::
          {:added, map()}
          | {:duplicate, map()}
          | {:elsewhere, map()}
          | {:error, atom() | term()}

  @doc "The file extensions the uploader takes, for `allow_upload/3`'s `:accept`."
  @spec accept() :: [String.t()]
  def accept, do: @extensions ++ raw_extensions()

  @doc """
  The camera raw extensions the uploader takes: those of
  `PhoenixKit.Modules.Storage.CameraRaw` whose type the host has given MIME, because
  LiveView refuses to set an upload up for an extension MIME does not know. A host
  turns them on with

      config :mime, :types, PhoenixKit.Modules.Storage.CameraRaw.mime_types()

  written out as a literal map (config cannot call the module), followed by
  `mix deps.compile mime --force`.
  """
  @spec raw_extensions() :: [String.t()]
  def raw_extensions do
    for ext <- Enum.sort(CameraRaw.extensions()),
        MIME.from_path("x." <> ext) == CameraRaw.mime_for_extension(ext),
        do: "." <> ext
  end

  @doc "The most files one batch may hold."
  @spec max_entries() :: pos_integer()
  def max_entries, do: @max_entries

  @doc """
  How many files the uploader's hook keeps in flight at once when it feeds a drop to
  LiveView: the panel's concurrency control starts here. The browser's own connection
  limit (about six over HTTP/1.1) still caps what really transfers at the same time.
  """
  @spec max_concurrent_uploads() :: pos_integer()
  def max_concurrent_uploads do
    @default_max_concurrent_uploads
    |> max(1)
    |> min(@max_concurrency_choice)
  end

  @doc "The most the panel's concurrency control offers."
  @spec max_concurrency_choice() :: pos_integer()
  def max_concurrency_choice, do: @max_concurrency_choice

  @doc "The largest file, in bytes: the site's `storage_max_upload_size_mb` setting."
  @spec max_file_size() :: pos_integer()
  def max_file_size do
    max(Settings.get_integer_setting("storage_max_upload_size_mb", @default_max_mb), 1) *
      1_048_576
  end

  @doc "The library, or nil."
  @spec library(term()) :: Library.t() | nil
  def library(uuid), do: Libraries.get_library(uuid)

  @doc "Whether `scope` may add files to the library `library_uuid`."
  @spec can_upload?(Scope.t() | nil, term()) :: boolean()
  def can_upload?(%Scope{} = scope, library_uuid) do
    user_uuid = Scope.user_uuid(scope)

    case is_binary(user_uuid) && Libraries.get_library(library_uuid) do
      %Library{kind: "user", trashed_at: nil} = library ->
        Libraries.allows?(Libraries.role(library, user_uuid), :upload)

      %Library{kind: "system", trashed_at: nil} ->
        Scope.system_role?(scope) or Scope.has_module_access?(scope, "media")

      _ ->
        false
    end
  end

  def can_upload?(_scope, _library_uuid), do: false

  @doc """
  Stores the finished upload at `path` (a LiveView upload `entry` says what it is
  called and what the browser thought it was) in the library, for `scope`'s user.

    * `{:added, file}` — a new file (a duplicate that had been trashed is restored and
      counts as added: uploading it again means it is wanted)
    * `{:duplicate, file}` — the same bytes are already in this library
    * `{:elsewhere, file}` — the same bytes are already in another of this person's
      libraries, which this one cannot show
    * `{:error, reason}` — `:not_allowed`, `:unsupported_type`, or what storage said
      (`:quota_exceeded` when the library's owner has no room left for it)
  """
  @spec store(Path.t(), map(), Scope.t() | nil, term()) :: outcome()
  def store(path, entry, scope, library_uuid) do
    name = clean_name(Map.get(entry, :client_name))
    mime = mime_for(entry, name)

    with :ok <- allowed(scope, library_uuid),
         {:ok, type, mime} <- media_type(path, mime, name),
         {:ok, hash} <- hash(path) do
      path
      |> Storage.store_file_in_buckets(
        type,
        Scope.user_uuid(scope),
        hash,
        extension(name),
        name,
        mime_type: mime,
        library_uuid: library_uuid,
        return_creation_status: true
      )
      |> authorized_outcome(scope, library_uuid)
    end
  rescue
    error ->
      Logger.warning(
        "[PhotoUploader] storing #{inspect(entry[:client_name])} failed: #{Exception.message(error)}"
      )

      {:error, :failed}
  catch
    :exit, reason ->
      Logger.warning("[PhotoUploader] storing an upload exited: #{inspect(reason)}")
      {:error, :failed}
  end

  @doc """
  The checks `store/4` starts with that cost next to nothing: whether `scope` may add
  to the library, and whether this is a file it takes (by its name, and for SVG and
  camera raw by its first 512 bytes). `:ok` or `store/4`'s `{:error, :not_allowed}` or
  `{:error, :unsupported_type}`. The uploader asks before it hands a file to
  `PhoenixKitPhotos.StoreUploadJob`, so a refusal is said at once; `store/4` asks again.
  """
  @spec precheck(Path.t(), map(), Scope.t() | nil, term()) :: :ok | {:error, atom()}
  def precheck(path, entry, scope, library_uuid) do
    name = clean_name(Map.get(entry, :client_name))

    with :ok <- allowed(scope, library_uuid),
         {:ok, _type, _mime} <- media_type(path, mime_for(entry, name), name) do
      :ok
    end
  end

  defp allowed(scope, library_uuid),
    do: if(can_upload?(scope, library_uuid), do: :ok, else: {:error, :not_allowed})

  defp authorized_outcome({:error, _} = error, _scope, _library_uuid), do: error

  defp authorized_outcome(result, scope, library_uuid) do
    if can_upload?(scope, library_uuid) do
      outcome(result, library_uuid)
    else
      compensate(result)
      {:error, :not_allowed}
    end
  end

  defp compensate({:ok, file, :created}) do
    case Storage.trash_file(file) do
      {:ok, _} ->
        :ok

      other ->
        Logger.warning(
          "[PhotoUploader] could not trash refused upload #{file.uuid}: #{inspect(other)}"
        )
    end
  end

  defp compensate(_result), do: :ok

  # An SVG is taken by its bytes, not by its name or the browser's word: a file called
  # .svg that is not one, or an SVG claimed under another name, is refused. Its type
  # is then always image/svg+xml, which is what keeps it from being shown as a page
  # (see the moduledoc). Compressed SVG (.svgz) is not taken.
  defp media_type(path, mime, name) do
    ext = name |> Path.extname() |> String.downcase()

    cond do
      ext == ".svg" -> if svg_bytes?(path), do: {:ok, "image", @svg}, else: unsupported()
      mime == @svg -> unsupported()
      ext in raw_extensions() -> raw(path, ext)
      ext not in @extensions -> unsupported()
      true -> type_of(Storage.determine_file_type(mime, name), mime)
    end
  end

  # A raw file is typed by its name (most are TIFF-shaped, so the bytes cannot say which
  # maker's it is), once its bytes have a raw file's shape.
  defp raw(path, ext) do
    if CameraRaw.raw_shaped?(path),
      do: {:ok, "image", CameraRaw.mime_for_extension(ext)},
      else: unsupported()
  end

  defp svg_bytes?(path), do: match?({:ok, %{format: :svg}}, Sniff.sniff(path))

  defp unsupported, do: {:error, :unsupported_type}

  defp type_of(type, mime) when type in ["image", "video"], do: {:ok, type, mime}
  defp type_of(_other, _mime), do: unsupported()

  defp hash(path) do
    case FileHash.sha256(path) do
      {:ok, hash} -> {:ok, hash}
      {:error, _reason} -> {:error, :file_missing}
    end
  end

  defp outcome({:ok, %{status: "trashed"} = file, :duplicate}, library_uuid) do
    if same_library?(file, library_uuid) do
      case Storage.restore_file_into(file, nil) do
        {:ok, restored} -> {:added, restored}
        {:error, :not_trashed} -> {:duplicate, Storage.get_file(file.uuid) || file}
        {:error, reason} -> {:error, reason}
      end
    else
      {:elsewhere, file}
    end
  end

  defp outcome({:ok, file, :duplicate}, library_uuid) do
    if same_library?(file, library_uuid), do: {:duplicate, file}, else: {:elsewhere, file}
  end

  defp outcome({:ok, file}, _library_uuid), do: {:added, file}
  defp outcome({:ok, file, :created}, _library_uuid), do: {:added, file}

  defp same_library?(file, library_uuid),
    do: to_string(file.library_uuid) == to_string(library_uuid)

  # The browser's name is only checked against `:accept`: a path (either separator),
  # control characters (a NUL fails the insert) and a bare "." or ".." never reach
  # storage as a file name, and the name fits the column with its extension kept.
  @max_name 255

  @doc false
  def clean_name(name) do
    name =
      name
      |> to_string()
      |> String.replace(~r/[\x00-\x1F\x7F]/u, "")
      |> String.split(["/", "\\"])
      |> List.last()
      |> String.trim()

    cond do
      name in ["", ".", ".."] -> "upload"
      String.length(name) <= @max_name -> name
      true -> bounded(name)
    end
  end

  defp bounded(name) do
    ext = Path.extname(name)
    keep = max(@max_name - String.length(ext), 1)
    String.slice(Path.rootname(name), 0, keep) <> ext
  end

  @doc false
  def mime_for(entry, name) do
    browser = entry |> Map.get(:client_type) |> to_string() |> String.downcase()

    if browser in ["", "application/octet-stream"], do: MIME.from_path(name), else: browser
  end

  defp extension(name),
    do: name |> Path.extname() |> String.trim_leading(".") |> String.downcase()

  @doc "What to tell a person about a rejected entry (`Phoenix.Component.upload_errors/2`)."
  @spec entry_error(atom() | tuple()) :: String.t()
  def entry_error(:too_large),
    do: gettext("Too large (the limit is %{mb} MB)", mb: div(max_file_size(), 1_048_576))

  def entry_error(:not_accepted),
    do: gettext("This kind of file is not supported (photos and videos only)")

  def entry_error(:too_many_files), do: gettext("Too many files at once")
  def entry_error(_other), do: gettext("This file could not be uploaded")

  @doc "What to tell a person about a file that did not get stored."
  @spec error_message(term()) :: String.t()
  def error_message({:rejected, reason}), do: entry_error(reason)
  def error_message(:not_allowed), do: gettext("You may not add to this library")
  def error_message(:unsupported_type), do: gettext("This kind of file is not supported")
  def error_message(:file_missing), do: gettext("The upload was lost on the way")

  def error_message(:quota_exceeded),
    do: gettext("There is no room left: this library's storage is full")

  def error_message(_other), do: gettext("The server could not save it")
end
