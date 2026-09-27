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
