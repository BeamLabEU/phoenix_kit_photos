defmodule PhoenixKitPhotos.Components.PhotoTimeline do
  @moduledoc """
  The timeline LiveComponent: index and current window on the server, geometry
  and recycling in the `PhotoTimeline` JS hook.

  ## Usage

      <.live_component
        module={PhoenixKitPhotos.Components.PhotoTimeline}
        id="library"
        scope={{:library, library_uuid}}
        auth={scope}
        layout={:square}
        columns={5}
        on_open="open_asset"
      />

  `scope` is `{:library, uuid}` — one storage library. `auth` is the current
  `PhoenixKit.Users.Auth.Scope`. The server checks that scope before it
  returns a file, and again when it mints a thumbnail URL.

  `layout` accepts `:square` only. Square heights are exact, which is why
  the grid does not need tombstone refinement. There is no `on_select`.

  `on_open`, when set, is sent to the parent LiveView as
  `{on_open, file_uuid}` when a tile is opened. The parent must authorize
  that client-supplied UUID through `Timeline.viewer_file/3` before opening it.

  Hosts subscribe using `on_mount {PhoenixKitPhotos.LiveUpdates, "library"}`;
  use the actual component ID in place of "library".
  """

  use Phoenix.LiveComponent

  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKitPhotos.Timeline

  @impl true
  def mount(socket) do
    {:ok,
     socket
     |> assign(:index, nil)
     |> assign(:sections, [])
     |> assign(:state, :empty)
     |> assign(:error, nil)
     |> assign(:revision, 0)}
  end

  @impl true
  def update(%{refresh: true}, socket) do
    {:ok, load_index(socket)}
  end

  def update(assigns, socket) do
    scope = validate_scope!(assigns.scope)
    auth = validate_auth!(assigns.auth)
    layout = validate_layout!(Map.get(assigns, :layout, :square))

    socket =
      socket
      |> assign(:id, assigns.id)
      |> assign(:scope, scope)
      |> assign(:auth, auth)
      |> assign(:layout, layout)
      |> assign(:columns, Map.get(assigns, :columns, 5))
      |> assign(:on_open, Map.get(assigns, :on_open))

    socket =
      if socket.assigns[:loaded_for] == {scope, auth} && socket.assigns.index do
        socket
      else
        load_index(socket)
      end

    {:ok, socket}
  end

  defp validate_scope!({:library, uuid} = scope) when is_binary(uuid), do: scope

  defp validate_scope!(other) do
    raise ArgumentError, """
    PhotoTimeline :scope must be {:library, uuid}, got: #{inspect(other)}

    The timeline is one storage library. Pass the library uuid, and pass the
    current PhoenixKit.Users.Auth.Scope as :auth.
    """
  end

  defp validate_auth!(%Scope{} = scope), do: scope
  defp validate_auth!(nil), do: nil

  defp validate_auth!(other) do
    raise ArgumentError,
          "PhotoTimeline :auth must be a PhoenixKit.Users.Auth.Scope, got: #{inspect(other)}"
  end

  defp validate_layout!(:square), do: :square

  defp validate_layout!(:justified) do
    raise ArgumentError, ":justified layout arrives in Stage 3; use :square"
  end

  defp validate_layout!(other) do
    raise ArgumentError, "PhotoTimeline :layout must be :square, got: #{inspect(other)}"
  end

  defp load_index(socket) do
    socket = assign(socket, :revision, socket.assigns.revision + 1)

    case Timeline.index(socket.assigns.scope, socket.assigns.auth) do
      {:ok, index} ->
        socket
        |> assign(:index, index)
        |> assign(:sections, index.sections)
        |> assign(:state, index.state)
        |> assign(:error, nil)
        |> assign(:loaded_for, {socket.assigns.scope, socket.assigns.auth})
        |> push_index(index)

      {:error, reason} ->
        socket
        |> assign(:index, nil)
        |> assign(:sections, [])
        |> assign(:state, :error)
        |> assign(:error, reason)
        |> assign(:loaded_for, {socket.assigns.scope, socket.assigns.auth})
    end
  end

  defp push_index(socket, index) do
    if connected?(socket) do
      {:library, library_uuid} = socket.assigns.scope

      push_event(socket, event(socket, "index"), %{
        revision: socket.assigns.revision,
        library: library_uuid,
        total: index.total,
        sections: Enum.map(index.sections, &section_payload/1),
        metrics: %{cell: 160, gap: 4, header: 40}
      })
    else
      socket
    end
  end

  defp section_payload(section) do
    %{
      id: section.id,
      label: section.label,
      count: section.count,
      sum_aspect: section.sum_aspect,
      days: section.days,
      days_list: section.days_list
    }
  end

  @impl true
  def handle_event("timeline:ready", _params, socket) do
    {:noreply, load_index(socket)}
  end

  def handle_event("timeline:need_window", %{"window" => day, "revision" => revision}, socket) do
    if revision == socket.assigns.revision do
      payload =
        case Timeline.window(socket.assigns.scope, day, socket.assigns.auth) do
          {:ok, window} -> window_payload(window)
          {:error, _reason} -> %{section: day, items: [], error: true}
        end

      {:noreply,
       push_event(socket, event(socket, "window"), Map.put(payload, :revision, revision))}
    else
      {:noreply, socket}
    end
  end

  def handle_event("timeline:jump", %{"id" => id}, socket) do
    {:noreply, push_event(socket, event(socket, "jump"), %{id: id})}
  end

  def handle_event("timeline:open", %{"id" => id}, socket) do
    if event = socket.assigns.on_open do
      send(self(), {event, id})
    end

    {:noreply, socket}
  end

  defp event(socket, name), do: "timeline:#{socket.assigns.id}:#{name}"

  defp window_payload(%{section: section, items: items}) do
    %{
      section: section,
      items:
        Enum.map(items, fn item ->
          %{
            id: item.id,
            taken_at: item.taken_at && DateTime.to_iso8601(item.taken_at),
            w: item.w,
            h: item.h,
            ar: item.ar,
            thumb: item.thumb,
            preview: item.preview,
            kind: item.kind
          }
        end)
    }
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id={@id} class="phoenix-kit-photo-timeline flex flex-col gap-3">
      <form id={"#{@id}-jump"} :if={@sections != []} phx-change="timeline:jump" phx-target={@myself} class="flex justify-end">
        <select name="id" class="select select-bordered select-sm" aria-label="Jump to month">
          <option :for={section <- @sections} value={section.id}>{section.label}</option>
        </select>
      </form>

      <div :if={@error} class="alert alert-warning" role="status">
        {error_message(@error)}
      </div>

      <div :if={@state in [:empty, :processing, :backfill]} class="alert alert-info" role="status">
        {state_message(@state)}
      </div>

      <div
        :if={!@error}
        id={"#{@id}-viewport"}
        phx-hook="PhotoTimeline"
        phx-update="ignore"
        data-timeline-id={@id}
        phx-target={@myself}
        data-target={@myself}
        data-columns={@columns}
        data-layout={@layout}
        class="phoenix-kit-photo-timeline__viewport relative h-[70vh] overflow-y-auto"
      >
        <div class="phoenix-kit-photo-timeline__spacer"></div>
        <div class="phoenix-kit-photo-timeline__layer pointer-events-none absolute inset-x-0 top-0"></div>
      </div>
    </div>
    """
  end

  defp state_message(:empty), do: "No photos yet."
  defp state_message(:processing), do: "Today's upload is still processing."
  defp state_message(:backfill), do: "Capture dates are still being filled in."

  defp error_message(:capture_date_unavailable) do
    "Photos needs capture-date columns on phoenix_kit_files. " <>
      "Nothing is shown rather than bucketing a library by upload date."
  end

  defp error_message(:not_found), do: "That library does not exist."
  defp error_message(:unauthorized), do: "Sign in to see this library."
  defp error_message(other), do: "Photos is unavailable: #{inspect(other)}"
end
