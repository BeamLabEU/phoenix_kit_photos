defmodule PhoenixKitPhotos.TestEndpoint do
  @moduledoc false
  use Phoenix.Endpoint, otp_app: :phoenix_kit_photos
  socket "/live", Phoenix.LiveView.Socket
end

defmodule PhoenixKitPhotos.TestLive do
  @moduledoc false
  use Phoenix.LiveView
  on_mount {PhoenixKitPhotos.LiveUpdates, "test-timeline"}

  def mount(_params, %{"scope" => scope, "library" => library}, socket) do
    {:ok, assign(socket, scope: scope, library: library)}
  end

  def render(assigns) do
    ~H"""
    <.live_component module={PhoenixKitPhotos.Components.PhotoTimeline}
      id="test-timeline" scope={@library} auth={@scope} />
    """
  end
end

defmodule PhoenixKitPhotos.UploadLive do
  @moduledoc false
  use Phoenix.LiveView

  def mount(_params, %{"scope" => scope, "library" => library} = session, socket) do
    {:ok,
     assign(socket, scope: scope, library: library, on_stored: session["on_stored"], stored: [])}
  end

  def handle_info({:stored, id, outcome}, socket) do
    {:noreply, assign(socket, :stored, [{id, outcome} | socket.assigns.stored])}
  end

  def handle_call(:stored, _from, socket), do: {:reply, socket.assigns.stored, socket}

  def render(assigns) do
    ~H"""
    <.live_component
      module={PhoenixKitPhotos.Components.PhotoUploader}
      id="test-uploader"
      library_uuid={@library}
      auth={@scope}
      on_stored={@on_stored}
    />
    """
  end
end

defmodule PhoenixKitPhotos.ViewerLive do
  @moduledoc false
  use Phoenix.LiveView

  def mount(_params, %{"scope" => scope, "library" => library}, socket) do
    {:ok, assign(socket, scope: scope, library: library, changed: [])}
  end

  def handle_info({:viewer_changed, uuid}, socket) do
    {:noreply, assign(socket, :changed, [uuid | socket.assigns.changed])}
  end

  def handle_call(:changed, _from, socket), do: {:reply, socket.assigns.changed, socket}

  def render(assigns) do
    ~H"""
    <.live_component
      module={PhoenixKitPhotos.Components.ViewerPicker}
      id="test-viewer"
      library_uuid={@library}
      auth={@scope}
    />
    """
  end
end
