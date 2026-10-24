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

  ## Filling the screen

  `fill` makes the timeline cover the whole window (`fixed inset-0`), the way a photo app
  does, with the grid scrolling under the host's header. The host says how tall that header
  is with the CSS length `--photo-timeline-inset-top` (any length: `3.5rem`,
  `calc(3.5rem + env(safe-area-inset-top))`) set on the timeline or an ancestor; the first
  row rests below it and a jump to a month lands under it. In this mode the "jump to month"
  select becomes a small floating pill that always shows the month at the top of the screen
  and opens the same list, and an empty library shows the `:empty` slot (or a plain line)
  in the middle of the screen instead of an alert.

  `cell` is a tile size in px to aim for: the number of columns then follows the width of
  the screen, as many tiles of about that size as fit (at least three), and `columns` is only
  the fallback. `gap` is the space between tiles in px (default 4).

      <.live_component module={PhotoTimeline} id="library" scope={...} auth={scope}
        fill cell={170} gap={2}>
        <:empty>Drop photos here</:empty>
      </.live_component>

  The person can zoom: pinch on a phone, pinch on a trackpad (Chrome, Edge, Firefox send it as
  ctrl + wheel; Safari as gesture events), or press `+`, `-` and `0` (back to the size the host
  asks for). While the fingers are down the grid is only scaled; when they lift it is laid out
  again with a whole number of columns, around the photo under the fingers. The size they chose
  is a tile size, kept in the browser (`localStorage`, `phoenix_kit_photos:cell`), so it carries
  over to another screen width and wins over `cell`. Tiles go down to 56 px and up to one column.

  `layout` accepts `:square` only. Square heights are exact, which is why
  the grid does not need tombstone refinement. There is no `on_select`.

  `pager` makes a click on a tile open the swipe viewer (in the `PhotoTimeline`
  hook) instead of sending `on_open`. `false` (the default) is no swipe viewer;
  `true` is the default engine; a string or atom (`"photoswipe"`, `"snap"`) names
  the engine. The engines are interchangeable behind one contract (see
  `assets/js/viewer/engine.js`); a name the page does not know falls back to the
  default one, and a host can offer a choice by passing the person's. The viewer
  asks this component for full-size slides (`timeline:slides`) as the person
  swipes, and its Info button sends `on_open` for the file on screen, so the
  host's own viewer (details, comments) is still one tap away.

  `on_open`, when set, is sent to the parent LiveView as
  `{on_open, file_uuid}` when a tile is opened. The parent must authorize
  that client-supplied UUID through `Timeline.viewer_file/3` before opening it.

  Hosts subscribe using `on_mount {PhoenixKitPhotos.LiveUpdates, "library"}`;
  use the actual component ID in place of "library".

  ## When files arrive

  Storage announces file events to everyone, so the component first asks whether the files are in
  its library (`Timeline.touches?/2`) and ignores the event if not. An upload is several events a
  file, so it gathers a burst (`config :phoenix_kit_photos, refresh_delay_ms: 350`) into one new
  index. The browser then keeps every tile where it is, fetches the windows it holds again, and
  swaps the answers in: a photo it has never seen pops in, the tiles after it glide aside, and
  when the person is looking at the end of the library the view follows it down. Nothing is
  cleared, so nothing flickers; an open swipe viewer is left alone until it is closed.
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
  # A storage event. Events are announced to everyone, so first: is it about this library at
  # all? Then coalesce: an upload is several events a file (processed, each thumbnail), and
  # one index per burst is plenty.
  def update(%{refresh: true} = assigns, socket) do
    cond do
      !Map.has_key?(socket.assigns, :scope) ->
        {:ok, socket}

      Map.has_key?(assigns, :file_uuids) and
          not Timeline.touches?(socket.assigns.scope, assigns.file_uuids) ->
        {:ok, socket}

      socket.assigns[:refresh_queued] ->
        {:ok, socket}

      true ->
        Phoenix.LiveView.send_update_after(
          __MODULE__,
          [id: socket.assigns.id, refresh_now: true],
          refresh_delay()
        )

        {:ok, assign(socket, :refresh_queued, true)}
    end
  end

  def update(%{refresh_now: true}, socket) do
    {:ok, socket |> assign(:refresh_queued, false) |> load_index()}
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
      |> assign(:fill, Map.get(assigns, :fill, false) == true)
      |> assign(:cell, positive_integer(Map.get(assigns, :cell)))
      |> assign(:gap, non_negative_integer(Map.get(assigns, :gap), 4))
      |> assign(:empty_slot, Map.get(assigns, :empty, []))
      |> assign(:on_open, Map.get(assigns, :on_open))
      |> assign(:pager, pager_setting(Map.get(assigns, :pager, false)))

    socket =
      if socket.assigns[:loaded_for] == {scope, auth} && socket.assigns.index do
        socket
      else
        load_index(socket)
      end

    {:ok, socket}
  end

  # How long a burst of storage events is gathered before the index is read again.
  defp refresh_delay, do: Application.get_env(:phoenix_kit_photos, :refresh_delay_ms, 350)

  defp positive_integer(value) when is_integer(value) and value > 0, do: value
  defp positive_integer(_value), do: nil

  defp non_negative_integer(value, _default) when is_integer(value) and value >= 0, do: value
  defp non_negative_integer(_value, default), do: default

  @doc false
  # What the hook reads from `data-pager`: "false", "true" (the default engine) or an
  # engine's name. Anything else is the default engine, so a bad value cannot
  # turn the swipe viewer off or put markup in the page.
  def pager_setting(value) when value in [false, nil], do: "false"
  def pager_setting(true), do: "true"
  def pager_setting(value) when is_atom(value), do: pager_setting(Atom.to_string(value))

  def pager_setting(value) when is_binary(value) do
    if Regex.match?(~r/\A[a-z0-9_-]{1,32}\z/, value), do: value, else: "true"
  end

  def pager_setting(_value), do: "true"

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
        metrics: %{cell: 160, gap: socket.assigns.gap, header: 40}
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

  def handle_event(
        "timeline:slides",
        %{
          "window" => day,
          "from" => from,
          "count" => count,
          "want" => want,
          "revision" => revision
        },
        socket
      )
      when is_integer(from) and is_integer(count) and is_integer(want) do
    if revision == socket.assigns.revision do
      payload =
        case Timeline.slides(socket.assigns.scope, day, from, count, want, socket.assigns.auth) do
          {:ok, items} -> %{items: items}
          {:error, _reason} -> %{items: [], error: true}
        end

      {:noreply,
       push_event(
         socket,
         event(socket, "slides"),
         Map.merge(payload, %{window: day, from: from, count: count, revision: revision})
       )}
    else
      {:noreply, socket}
    end
  end

  def handle_event("timeline:slides", _params, socket), do: {:noreply, socket}

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
    <div
      id={@id}
      class={[
        "phoenix-kit-photo-timeline",
        @fill && "fixed inset-0",
        !@fill && "flex flex-col gap-3"
      ]}
      data-pager={to_string(@pager)}
    >
      <form
        :if={@sections != [] && !@fill}
        id={"#{@id}-jump"}
        phx-change="timeline:jump"
        phx-target={@myself}
        class="flex justify-end"
      >
        <select name="id" class="select select-bordered select-sm" aria-label="Jump to month">
          <option :for={section <- @sections} value={section.id}>{section.label}</option>
        </select>
      </form>

      <%!-- Filling the screen: the month at the top, as a pill under the header. The
           invisible select over it is the list; the browser's own picker opens, which
           is the right one on a phone. --%>
      <form
        :if={@sections != [] && @fill}
        id={"#{@id}-jump"}
        phx-change="timeline:jump"
        phx-target={@myself}
        class="absolute right-3 z-10"
        style="top: calc(var(--photo-timeline-inset-top, 0px) + 0.5rem)"
      >
        <label class="relative flex cursor-pointer items-center gap-1 rounded-full border border-base-content/10 bg-base-100/50 py-1.5 pl-3 pr-2 text-sm font-medium shadow-sm backdrop-blur-md">
          <span id={"#{@id}-current"} data-current-section phx-update="ignore"></span>
          <span class="hero-chevron-down size-4 opacity-60" aria-hidden="true"></span>
          <select
            name="id"
            class="absolute inset-0 h-full w-full cursor-pointer opacity-0"
            aria-label="Jump to month"
          >
            <option :for={section <- @sections} value={section.id}>{section.label}</option>
          </select>
        </label>
      </form>

      <div :if={@error && !@fill} class="alert alert-warning" role="status">
        {error_message(@error)}
      </div>

      <div
        :if={@state in [:processing, :backfill] && !@fill}
        class="alert alert-info"
        role="status"
      >
        {state_message(@state)}
      </div>

      <div :if={@state == :empty && !@fill} class="alert alert-info" role="status">
        {state_message(:empty)}
      </div>

      <%!-- Filling the screen there is no room for alerts above the grid: what there is to
           say is said over it, in the middle. --%>
      <div
        :if={@fill && (@error || @state == :empty)}
        class="pointer-events-none absolute inset-0 z-10 grid place-items-center px-6 text-center"
        role="status"
      >
        <div :if={@error} class="max-w-sm text-warning">{error_message(@error)}</div>
        <div :if={!@error and @empty_slot != []} class="pointer-events-auto max-w-sm">
          {render_slot(@empty_slot)}
        </div>
        <div :if={!@error and @empty_slot == []} class="text-base-content/60">
          {state_message(:empty)}
        </div>
      </div>

      <div
        :if={@fill && !@error && @state in [:processing, :backfill]}
        class="pointer-events-none absolute inset-x-0 bottom-4 z-10 flex justify-center px-4"
        role="status"
      >
        <span class="rounded-full border border-base-content/10 bg-base-100/80 px-4 py-2 text-sm shadow backdrop-blur-md">
          {state_message(@state)}
        </span>
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
        data-cell={@cell}
        data-gap={@gap}
        data-fill={to_string(@fill)}
        data-layout={@layout}
        class={[
          "phoenix-kit-photo-timeline__viewport relative touch-pan-y overflow-y-auto",
          @fill && "h-full overscroll-contain",
          !@fill && "h-[70vh]"
        ]}
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
