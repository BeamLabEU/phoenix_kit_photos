defmodule PhoenixKitPhotos.Components.ViewerPicker do
  @moduledoc """
  A select for the viewer of one library (`PhoenixKitPhotos.Viewer`): "Default", "Swipe
  viewer", "Classic viewer". It shows nothing to someone who may not choose
  (`Viewer.can_set?/2`), and checks again when it saves.

  ## Usage

      <.live_component
        module={PhoenixKitPhotos.Components.ViewerPicker}
        id="viewer-picker"
        library_uuid={library_uuid}
        auth={scope}
      />

  When the choice is saved the parent LiveView gets `{:viewer_changed, library_uuid}` and
  reads `PhoenixKitPhotos.Viewer.for_library/1` again.
  """

  use Phoenix.LiveComponent
  use Gettext, backend: PhoenixKitPhotos.Gettext

  alias PhoenixKit.Modules.Storage.Libraries
  alias PhoenixKitPhotos.Viewer

  @impl true
  def update(assigns, socket) do
    library = Libraries.get_library(assigns.library_uuid)

    {:ok,
     socket
     |> assign(:notify, Map.get(assigns, :notify, true))
     |> assign(:id, assigns.id)
     |> assign(:library_uuid, assigns.library_uuid)
     |> assign(:auth, assigns.auth)
     |> assign(:library, library)
     |> assign(:can_set?, Viewer.can_set?(assigns.auth, library))
     |> assign(:chosen, library && Viewer.chosen(library))
     |> assign(:error, nil)}
  end

  @impl true
  def handle_event("set", %{"viewer" => value}, socket) do
    name = if value == "", do: nil, else: value

    case Viewer.put(socket.assigns.auth, socket.assigns.library, name) do
      {:ok, library} ->
        if socket.assigns.notify, do: send(self(), {:viewer_changed, socket.assigns.library_uuid})

        PhoenixKit.PubSub.Manager.broadcast(
          "storage:library_settings",
          {:library_settings_changed, socket.assigns.library_uuid}
        )

        {:noreply, assign(socket, library: library, chosen: Viewer.chosen(library), error: nil)}

      {:error, _reason} ->
        {:noreply, assign(socket, :error, gettext("Could not save the viewer"))}
    end
  end

  def handle_event("set", _params, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <div id={@id}>
      <div :if={@can_set?} class="flex items-center gap-2">
        <form id={"#{@id}-form"} phx-change="set" phx-target={@myself}>
          <select
            name="viewer"
            class="select select-bordered select-sm"
            aria-label={gettext("Viewer")}
            title={gettext("How this library's photos open")}
          >
            <option value="" selected={is_nil(@chosen)}>
              {gettext("Default (%{name})", name: label(Viewer.default()))}
            </option>
            <option :for={{name, label} <- Viewer.options()} value={name} selected={@chosen == name}>
              {label}
            </option>
          </select>
        </form>
        <span :if={!@notify} class="text-xs text-base-content/60">{gettext(
          "Changes are saved automatically."
        )}</span>
        <span :if={@error} class="text-error text-sm" role="alert">{@error}</span>
      </div>
    </div>
    """
  end

  defp label(name) do
    case List.keyfind(Viewer.options(), name, 0) do
      {_name, label} -> label
      nil -> name
    end
  end
end
