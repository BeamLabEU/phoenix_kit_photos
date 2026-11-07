defmodule PhoenixKitPhotos.Web.Download do
  @moduledoc """
  The timeline's Download: a form post of file ids, answered with a ZIP of the originals as they
  are read. A host mounts it in a pipeline with the session, CSRF protection and the current
  scope, and tells the timeline where (`download_path`):

      post "/photos/download", PhoenixKitPhotos.Web.Download, []

  Every id is checked for the person asking (`Bulk.plan/4`, `:download`). Someone who may not
  read a file gets it left out, not told it exists. Visitors of a public library may download
  from it too: if they may see a photo, they may have it.
  """

  @behaviour Plug

  import Plug.Conn

  alias PhoenixKit.Modules.Storage
  alias PhoenixKitPhotos.Bulk
  alias PhoenixKitPhotos.Zip

  require Logger

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    ids = conn.params |> Map.get("ids", "") |> to_string() |> String.split(",", trim: true)
    scope = conn.assigns[:phoenix_kit_current_scope]

    case Bulk.plan(:download, ids, scope).files do
      [] -> conn |> send_resp(404, "") |> halt()
      files -> conn |> stream(files) |> halt()
    end
  end

  defp stream(conn, files) do
    name = "photos-#{Date.utc_today()}.zip"

    conn =
      conn
      |> put_resp_content_type("application/zip", nil)
      |> put_resp_header("content-disposition", ~s(attachment; filename="#{name}"))
      |> put_resp_header("cache-control", "private, no-store")
      |> send_chunked(200)

    {conn, zip, _names} = Enum.reduce_while(files, {conn, Zip.new(), %{}}, &add/2)

    case chunk(conn, Zip.finish(zip)) do
      {:ok, conn} -> conn
      {:error, _reason} -> conn
    end
  end

  # A file that cannot be read now is left out, and the others still arrive. Someone who closed
  # the tab has stopped listening, and the rest are not read for nobody.
  defp add(file, {conn, zip, names}) do
    {name, names} = unique_name(file, names)

    case Storage.retrieve_file(file.uuid) do
      {:ok, path, _file} ->
        key = {__MODULE__, make_ref()}
        Process.put(key, conn)

        write = fn data ->
          case chunk(Process.get(key), data) do
            {:ok, conn} ->
              Process.put(key, conn)
              :ok

            {:error, reason} ->
              {:error, reason}
          end
        end

        result = Zip.add(zip, name, path, file.taken_at, write)
        conn = Process.delete(key)
        File.rm(path)

        case result do
          {:ok, zip} ->
            {:cont, {conn, zip, names}}

          {:error, _reason} ->
            {:halt, {conn, zip, names}}
        end

      _error ->
        Logger.warning("[PhotoDownload] a file could not be read and was left out of the archive")
        {:cont, {conn, zip, names}}
    end
  end

  # Cameras repeat themselves: `IMG_0001.jpg` twice becomes `IMG_0001 (2).jpg`.
  defp unique_name(file, names) do
    name = file.original_file_name || file.file_name || file.uuid
    name = name |> Path.basename() |> String.replace(~r/[\x00-\x1f\/\\]/u, "_")
    seen = Map.get(names, String.downcase(name), 0)
    names = Map.put(names, String.downcase(name), seen + 1)

    if seen == 0 do
      {name, names}
    else
      ext = Path.extname(name)
      {"#{Path.rootname(name)} (#{seen + 1})#{ext}", names}
    end
  end
end
