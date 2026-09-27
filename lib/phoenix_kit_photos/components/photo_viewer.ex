defmodule PhoenixKitPhotos.Components.PhotoViewer do
  @moduledoc """
  Hosts PhoenixKit's canvas viewer and dialog hook for one authorized photo.
  Pass only the file data returned by `Timeline.viewer_file/3`. Stage 1 is
  read-only; editing and annotations remain in PhoenixKit's media screens.
  """
  use Phoenix.LiveComponent
  alias PhoenixKitWeb.Components.MediaCanvasViewer

  @impl true
  def update(assigns, socket), do: {:ok, assign(socket, assigns)}

  @impl true
  def handle_event("close_viewer", _params, socket), do: close(socket)
  def handle_event("viewer_keydown", %{"key" => "Escape"}, socket), do: close(socket)
  def handle_event("viewer_keydown", _params, socket), do: {:noreply, socket}
  def handle_event("step_viewer", _params, socket), do: {:noreply, socket}

  defp close(socket) do
    send(self(), :photos_viewer_closed)
    {:noreply, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <dialog id={@id} class="modal" phx-hook="MediaViewerDialog" phx-target={@myself} aria-label={@file.filename}>
      <div class="modal-box w-[95vw] max-w-none h-[90vh] p-0 overflow-hidden">
        <.live_component module={MediaCanvasViewer} id={"#{@id}-#{@file.file_uuid}"}
          file={@file} current_user={@current_user} parent_id={@id}
          has_prev={false} has_next={false} can_annotate={false} />
      </div>
      <div class="modal-backdrop" phx-click="close_viewer" phx-target={@myself}></div>
    </dialog>
    """
  end
end
