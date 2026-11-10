defmodule PhoenixKitPhotos.UploadStaging do
  @moduledoc """
  Where the uploader keeps a finished upload between LiveView handing it over and
  `PhoenixKitPhotos.StoreUploadJob` storing it.

  LiveView's temp file belongs to the upload's channel and is deleted when that channel
  ends, which a page reload or a lost connection does at any moment. So the uploader
  takes the file out of LiveView's hands at once (`stage/1`, a rename) and stores it
  later, off the page. A store can take as long as storage needs without the page
  waiting for it: a page that does not answer a push within the socket's timeout is
  disconnected and reloaded by LiveView's client, which used to end every upload in
  flight (`dev_docs/plans/2026-11-10-resilient-photo-uploads.md` in Fotki).

  ## Where

  `config :phoenix_kit_photos, :staging_dir, "/path"`; by default
  `phoenix_kit_photos_staging` in the system's temp directory (`System.tmp_dir!/0`).
  Put it on the **same filesystem** as LiveView's temp files (Plug's, chosen by
  `PLUG_TMPDIR`, `TMPDIR`, `TMP` or `TEMP`): the move is then a rename and takes no
  time whatever the file's size. Across filesystems it is a copy, which for a large
  video can take long enough to bring the old trouble back, and a warning says so. The
  directory must outlive an application restart (the job may run after one); a temp
  directory on the container's disk does.

  Staged files are named by a fresh UUID; what the file is (its name, type, library,
  uploader) travels in the job's arguments. `sweep/1` removes leftovers.
  """

  require Logger

  @subdir "phoenix_kit_photos_staging"

  @doc "The staging directory (see the moduledoc)."
  @spec dir() :: Path.t()
  def dir do
    case Application.get_env(:phoenix_kit_photos, :staging_dir) do
      dir when is_binary(dir) and dir != "" -> dir
      _ -> Path.join(System.tmp_dir!(), @subdir)
    end
  end

  @doc """
  Moves the file at `path` into the staging directory and returns where it now is.
  The file is gone from `path` afterwards.
  """
  @spec stage(Path.t()) :: {:ok, Path.t()} | {:error, term()}
  def stage(path) do
    dir = dir()
    target = Path.join(dir, Ecto.UUID.generate())

    with :ok <- File.mkdir_p(dir) do
      case File.rename(path, target) do
        :ok -> {:ok, target}
        {:error, :exdev} -> copy(path, target)
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp copy(path, target) do
    Logger.warning(
      "[PhotoUploader] the staging directory #{dir()} is on another filesystem than " <>
        "LiveView's temp files, so each upload is copied, not moved. Set " <>
        "config :phoenix_kit_photos, :staging_dir (or PLUG_TMPDIR) so both share one."
    )

    case File.cp(path, target) do
      :ok ->
        _ = File.rm(path)
        {:ok, target}

      {:error, reason} ->
        _ = File.rm(target)
        {:error, reason}
    end
  end

  @doc "Whether `path` is a file in the staging directory (a job's argument is checked)."
  @spec staged?(term()) :: boolean()
  def staged?(path) when is_binary(path) do
    Path.dirname(Path.expand(path)) == Path.expand(dir()) and
      match?({:ok, _}, Ecto.UUID.cast(Path.basename(path)))
  end

  def staged?(_path), do: false

  @doc "Deletes a staged file; a file already gone is fine."
  @spec discard(Path.t()) :: :ok
  def discard(path) do
    if staged?(path), do: _ = File.rm(path)
    :ok
  end

  @doc """
  Deletes staged files older than `max_age_seconds` that `keep` (a set of paths, the
  files a job still waits to store) does not name: what a crash left behind. Returns
  how many went.
  """
  @spec sweep(MapSet.t(), pos_integer()) :: non_neg_integer()
  def sweep(keep, max_age_seconds \\ 86_400) do
    dir = dir()
    cutoff = System.os_time(:second) - max_age_seconds

    case File.ls(dir) do
      {:ok, names} ->
        Enum.count(names, fn name ->
          path = Path.join(dir, name)

          staged?(path) and not MapSet.member?(keep, path) and old?(path, cutoff) and
            File.rm(path) == :ok
        end)

      {:error, _reason} ->
        0
    end
  end

  defp old?(path, cutoff) do
    case File.stat(path, time: :posix) do
      {:ok, %{type: :regular, mtime: mtime}} -> mtime < cutoff
      _ -> false
    end
  end
end
