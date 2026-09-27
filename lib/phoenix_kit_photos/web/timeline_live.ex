defmodule PhoenixKitPhotos.Web.TimelineLive do
  @moduledoc """
  The package's default timeline page.

  A host that wants its own branding declares its own route at the same path
  *before* `phoenix_kit_routes()` in its router — first match wins, so the host
  page shadows this one while every other install still gets a working page.
  """

  use PhoenixKitWeb, :live_view

  on_mount {PhoenixKitPhotos.LiveUpdates, "photo-timeline"}

  alias PhoenixKitPhotos.Components.PhotoTimeline
  alias PhoenixKitPhotos.Components.PhotoViewer
  alias PhoenixKitPhotos.Timeline
  alias PhoenixKitWeb.Components.LayoutWrapper

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, :page_title, gettext("Photos"))}
  end

  @impl true
  def handle_params(params, uri, socket) do
    scope = socket.assigns[:phoenix_kit_current_scope]
    libraries = Timeline.libraries(scope)

    library_uuid =
      choose_library(libraries, params["library"], Timeline.default_library_uuid(scope))

    viewer_file =
      case Timeline.viewer_file({:library, library_uuid}, params["at"], scope) do
        {:ok, file} -> file
        _ -> nil
      end

    {:noreply,
     assign(socket,
       libraries: libraries,
       library_uuid: library_uuid,
       viewer_file: viewer_file,
       photos_path: URI.parse(uri).path
     )}
  end

  @impl true
  def handle_event("library", %{"library" => id}, socket) do
    {:noreply, push_patch(socket, to: library_path(socket, id))}
  end

  @impl true
  def handle_info({:open_photo, uuid}, socket) do
    params = URI.encode_query(%{library: socket.assigns.library_uuid, at: uuid})
    {:noreply, push_patch(socket, to: socket.assigns.photos_path <> "?" <> params)}
  end

  def handle_info(:photos_viewer_closed, socket) do
    params = URI.encode_query(%{library: socket.assigns.library_uuid})
    {:noreply, push_patch(socket, to: socket.assigns.photos_path <> "?" <> params)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <LayoutWrapper.app_layout
      socket={@socket}
      flash={@flash}
      phoenix_kit_current_scope={assigns[:phoenix_kit_current_scope]}
      page_title={gettext("Photos")}
      current_path={assigns[:url_path]}
    >
      <div :if={is_nil(@library_uuid)} class="alert alert-info" role="status">
        {gettext("Sign in to see your photo library.")}
      </div>

      <form id="photo-library-picker" :if={@library_uuid && @libraries != []} phx-change="library" class="mb-4 flex justify-end">
        <select name="library" class="select select-bordered select-sm" aria-label={gettext("Library")}>
          <option :for={library <- @libraries} value={library.uuid} selected={library.uuid == @library_uuid}>
            {library.name}
          </option>
        </select>
      </form>

      <.live_component
        :if={@library_uuid}
        module={PhotoTimeline}
        id="photo-timeline"
        scope={{:library, @library_uuid}}
        auth={assigns[:phoenix_kit_current_scope]}
        layout={:square}
        columns={5}
        on_open={:open_photo}
      />
      <.live_component :if={@viewer_file} module={PhotoViewer} id="photos-viewer"
        file={@viewer_file} current_user={@phoenix_kit_current_scope.user} />
    </LayoutWrapper.app_layout>
    """
  end

  defp choose_library(libraries, requested, default) do
    ids = Enum.map(libraries, & &1.uuid)

    cond do
      requested in ids -> requested
      default in ids -> default
      true -> nil
    end
  end

  defp library_path(socket, id) do
    path = socket.assigns[:url_path] || "/photos"
    base = path |> String.split("?") |> hd()
    base <> "?" <> URI.encode_query(%{"library" => id})
  end
end
