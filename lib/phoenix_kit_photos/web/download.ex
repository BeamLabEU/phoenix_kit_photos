defmodule PhoenixKitPhotos.Web.Download do
  @moduledoc """
  The timeline's Download: a form post of file ids, answered with a ZIP of the originals as they
  are read. A host mounts it in a pipeline with the session, CSRF protection and the current
  scope, and tells the timeline where (`download_path`):

      post "/photos/download", PhoenixKitPhotos.Web.Download, []

  Every id is checked for the person asking (`Bulk.plan/4`, `:download`). Someone who may not
  read a file gets it left out, not told it exists. Visitors of a public library may download
  from it too, up to 200 files at a time and 10 times an hour for an address: if they may
  see a photo they may have it, but a site's bandwidth is not theirs to use up.

  A visitor is anyone the site does not admit as signed in (`Libraries.authenticated_reader?/1`:
  active, email confirmed). A session alone is not that, since one is minted for an account
  nobody confirmed, and an address typed into the sign-up form would otherwise lift the limits.

  The status of a streamed answer is sent before the first file is read, so a file that cannot
  be read later is reported inside the archive, in `Not included.txt`. A failure halfway through
  a file ends the answer without the archive's directory: broken, and visibly so, rather than
  quietly short.
  """

  @behaviour Plug

  use Gettext, backend: PhoenixKitPhotos.Gettext

  import Plug.Conn

  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Modules.Storage.Libraries
  alias PhoenixKit.Utils.IpAddress
  alias PhoenixKitPhotos.Bulk
  alias PhoenixKitPhotos.Zip

  require Logger

  @visitor_files 200
  @visitor_downloads 10
  @visitor_window :timer.hours(1)

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    scope = conn.assigns[:phoenix_kit_current_scope]
    signed_in? = Libraries.authenticated_reader?(scope)
    ids = conn.params |> Map.get("ids") |> requested_ids()
    ids = if signed_in?, do: ids, else: Enum.take(ids, @visitor_files)

    if signed_in? or allowed?(conn) do
      answer(conn, Bulk.plan(:download, ids, scope).files)
    else
      conn |> send_resp(429, "") |> halt()
    end
  end

  # A comma-separated string, as the timeline's form posts it. Anything else asks for nothing.
  defp requested_ids(ids) when is_binary(ids), do: String.split(ids, ",", trim: true)
  defp requested_ids(_other), do: []

  defp answer(conn, []), do: conn |> send_resp(404, "") |> halt()
  defp answer(conn, files), do: conn |> stream(files) |> halt()

  defp allowed?(conn) do
    key = "phoenix_kit_photos:download:#{IpAddress.extract_from_conn(conn)}"
    match?({:allow, _count}, rate_limit().hit(key, @visitor_window, @visitor_downloads))
  rescue
    # Without a limiter to ask, a visitor's download is not worth an error page.
    _error -> true
  end

  defp rate_limit, do: PhoenixKit.Users.RateLimiter.Backend

  defp stream(conn, files) do
    name = "photos-#{Date.utc_today()}.zip"

    conn =
      conn
      |> put_resp_content_type("application/zip", nil)
      |> put_resp_header("content-disposition", ~s(attachment; filename="#{name}"))
      |> put_resp_header("cache-control", "private, no-store")
      |> send_chunked(200)

    # A chunk gives back a new conn, and `Zip` knows nothing of conns: it writes through here.
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

    with {:ok, zip, missing} <- add_files(files, write),
         {:ok, zip} <- add_note(zip, missing, write) do
      write.(Zip.finish(zip))
    end

    Process.delete(key)
  end

  defp add_files(files, write) do
    files
    |> Enum.reduce_while({Zip.new(), [], MapSet.new()}, fn file, {zip, missing, names} ->
      {name, names} = unique_name(file, names)

      case add_file(zip, file, name, write) do
        {:ok, zip} -> {:cont, {zip, missing, names}}
        :left_out -> {:cont, {zip, [name | missing], names}}
        :stop -> {:halt, :stop}
      end
    end)
    |> case do
      {zip, missing, _names} -> {:ok, zip, Enum.reverse(missing)}
      :stop -> :stop
    end
  end

  # Someone who closed the tab has stopped listening, and the rest are not read for nobody.
  defp add_file(zip, file, name, write) do
    case Storage.retrieve_file(file.uuid) do
      {:ok, path, _file} ->
        result = Zip.add(zip, name, path, file.taken_at, write)
        File.rm(path)

        case result do
          {:ok, zip} -> {:ok, zip}
          {:error, {:read, _reason}} -> :left_out
          {:error, {:write, _reason}} -> :stop
        end

      _error ->
        Logger.warning("[PhotoDownload] a file could not be read and was left out of the archive")
        :left_out
    end
  end

  defp add_note(zip, [], _write), do: {:ok, zip}

  defp add_note(zip, missing, write) do
    title = gettext("These files could not be read just now, and are not in this archive:")
    Zip.add_text(zip, "Not included.txt", Enum.join([title | missing], "\r\n"), write)
  end

  # Cameras repeat themselves: `IMG_0001.jpg` twice becomes `IMG_0001 (2).jpg`, and a third that
  # really is called that moves on to the next free name.
  defp unique_name(file, names) do
    name = file.original_file_name || file.file_name || file.uuid
    name = name |> Path.basename() |> String.replace(~r/[\x00-\x1f\/\\]/u, "_")
    free = free_name(name, names, 1)
    {free, MapSet.put(names, String.downcase(free))}
  end

  defp free_name(name, names, number) do
    candidate =
      if number == 1,
        do: name,
        else: "#{Path.rootname(name)} (#{number})#{Path.extname(name)}"

    if MapSet.member?(names, String.downcase(candidate)),
      do: free_name(name, names, number + 1),
      else: candidate
  end
end
