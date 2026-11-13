defmodule PhoenixKitPhotos.Components.SharingSettings do
  @moduledoc """
  A library's choices of what it shares beyond its photos (`PhoenixKitPhotos.Sharing`): who
  sees where they were taken, and who may comment. For the library settings' tabs
  (`config :phoenix_kit, :library_settings_components`); it shows the choices read-only to
  someone who may not change them, and checks again when it saves.

      <.live_component
        module={PhoenixKitPhotos.Components.SharingSettings}
        id="sharing"
        library_uuid={library_uuid}
        auth={scope}
      />

  A saved choice is announced on `storage:library_settings` like the viewer's, so an open
  library page reads it again.
  """

  use Phoenix.LiveComponent
  use Gettext, backend: PhoenixKitPhotos.Gettext

  alias PhoenixKit.Modules.Storage.Libraries
  alias PhoenixKit.PubSub.Manager
  alias PhoenixKitPhotos.{Sharing, Viewer}

  @impl true
  def update(assigns, socket) do
    library = Libraries.get_library(assigns.library_uuid)

    {:ok,
     socket
     |> assign(:id, assigns.id)
     |> assign(:library_uuid, assigns.library_uuid)
     |> assign(:auth, assigns.auth)
     |> assign(:library, library)
     |> assign(:can_set?, Viewer.can_set?(assigns.auth, library))
     |> assign(:locations, library && Sharing.locations(library))
     |> assign(:comments, library && Sharing.comments(library))
     |> assign(:saved, nil)
     |> assign(:error, nil)}
  end

  @impl true
  def handle_event("set", %{"key" => key, "value" => value}, socket)
      when key in ["locations", "comments"] do
    case Sharing.put(socket.assigns.auth, socket.assigns.library, key, value) do
      {:ok, library} ->
        Manager.broadcast(
          "storage:library_settings",
          {:library_settings_changed, socket.assigns.library_uuid}
        )

        {:noreply,
         assign(socket,
           library: library,
           locations: Sharing.locations(library),
           comments: Sharing.comments(library),
           saved: key,
           error: nil
         )}

      {:error, _reason} ->
        {:noreply, assign(socket, :error, gettext("Could not save that."))}
    end
  end

  def handle_event("set", _params, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <div id={@id} class="space-y-6">
      <p :if={!@can_set?} class="text-sm text-base-content/60">
        {gettext("These are chosen by the library's owner and managers.")}
      </p>

      <.choice
        id={"#{@id}-locations"}
        key="locations"
        title={gettext("Who sees where photos were taken")}
        hint={
          gettext(
            "Phones record the exact spot in every photo. Downloaded originals can still carry it."
          )
        }
        options={Sharing.location_options()}
        value={@locations}
        disabled={!@can_set?}
        saved={@saved == "locations"}
        myself={@myself}
      />

      <.choice
        id={"#{@id}-comments"}
        key="comments"
        title={gettext("Who may comment")}
        options={Sharing.comment_options()}
        value={@comments}
        disabled={!@can_set?}
        saved={@saved == "comments"}
        myself={@myself}
      />

      <p :if={@error} class="text-sm text-error" role="alert">{@error}</p>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :key, :string, required: true
  attr :title, :string, required: true
  attr :hint, :string, default: nil
  attr :options, :list, required: true
  attr :value, :string
  attr :disabled, :boolean
  attr :saved, :boolean
  attr :myself, :any, required: true

  defp choice(assigns) do
    ~H"""
    <fieldset id={@id} class="space-y-2">
      <legend class="mb-1 flex items-center gap-2 text-sm font-semibold">
        {@title}
        <span :if={@saved} class="text-xs font-normal text-success" role="status">
          {gettext("Saved")}
        </span>
      </legend>
      <p :if={@hint} class="text-xs text-base-content/60">{@hint}</p>
      <label
        :for={{name, label, explanation} <- @options}
        class={[
          "flex items-start gap-3 rounded-box border p-3 transition",
          @value == name && "border-primary bg-primary/5",
          @value != name && "border-base-content/10",
          !@disabled && "cursor-pointer hover:border-primary/50"
        ]}
      >
        <input
          type="radio"
          name={"#{@id}-value"}
          value={name}
          checked={@value == name}
          disabled={@disabled}
          phx-click="set"
          phx-value-key={@key}
          phx-value-value={name}
          phx-target={@myself}
          class="radio radio-sm radio-primary mt-0.5"
        />
        <span>
          <span class="block text-sm font-medium">{label}</span>
          <span class="block text-xs text-base-content/60">{explanation}</span>
        </span>
      </label>
    </fieldset>
    """
  end
end
