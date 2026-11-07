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

  ## Styles

  `layout` is the style a person sees first: `:square` (the plain grid), `:rows`, `:columns`,
  `:mosaic`, `:whole`, `:feed`, `:prints`, `:film`, `:honeycomb` or `:details`. `styles` puts
  a menu by the month pill that lets them change it: `true` for all of them, or a list of the
  ones to offer. Their pick is kept in the browser (`localStorage`,
  `phoenix_kit_photos:style`) and wins over `layout`. `v` steps through the styles.

  A change of style is an animation in the browser and asks nothing of the server, except
  the first time a style needs the aspect ratio of every file (`Timeline.aspects/2`). Every
  style's heights are exact, so the scrollbar, a jump to a month, the bookmark and the swipe
  viewer's way back work the same in all of them.

  `pager` makes a click on a tile open the swipe viewer (in the `PhotoTimeline`
  hook) instead of sending `on_open`. `false` (the default) is no swipe viewer;
  `true` is the default engine; a string or atom (`"photoswipe"`, `"snap"`) names
  the engine. The engines are interchangeable behind one contract (see
  `assets/js/viewer/engine.js`); a name the page does not know falls back to the
  default one, and a host can offer a choice by passing the person's. The viewer
  asks this component for full-size slides (`timeline:slides`) as the person
  swipes, and its Info button sends `on_open` for the file on screen, so the
  host's own viewer (details, comments) is still one tap away.

  ## Addresses

  With `photo_path` and `library_path` the swipe viewer keeps the page's address in step with
  the photo on screen, so a photo can be shared, bookmarked, opened in a new tab and left with
  the Back button. `photo_path` is the address of a photo with `:code` where its short code goes
  (`"/anna/private/p/:code"`), `library_path` the address of the library
  (`"/anna/private"`). Both are paths on the host's own site. The viewer opening adds a history
  entry, turning to another photo replaces it, and closing the viewer goes back (or, when the
  page was opened on a photo, to `library_path`). The changes go through LiveView
  (`JS.patch`), so the parent's `handle_params/3` sees every address.

  The other way round, the parent tells the browser which photo its address names, on load and
  whenever the address changes (a Back to the library closes the viewer; a link to a photo opens
  it): `push_view/5`. The browser leaves a viewer that already shows that photo alone.

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
  use Gettext, backend: PhoenixKitPhotos.Gettext

  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKitPhotos.Timeline

  @styles ~w(grid rows columns mosaic whole feed prints film honeycomb details)
  @layouts Map.new(@styles, &{String.to_atom(&1), &1}) |> Map.put(:square, "grid")

  @impl true
  def mount(socket) do
    {:ok,
     socket
     |> assign(:aspects_wanted, false)
     |> assign(:aspects_sent, %{})
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
      |> assign(:styles, offered_styles(Map.get(assigns, :styles, false)))
      |> assign(:columns, Map.get(assigns, :columns, 5))
      |> assign(:fill, Map.get(assigns, :fill, false) == true)
      |> assign(:cell, positive_integer(Map.get(assigns, :cell)))
      |> assign(:gap, non_negative_integer(Map.get(assigns, :gap), 4))
      |> assign(:empty_slot, Map.get(assigns, :empty, []))
      |> assign(:on_open, Map.get(assigns, :on_open))
      |> assign(:pager, pager_setting(Map.get(assigns, :pager, false)))
      |> assign(:photo_path, photo_path(Map.get(assigns, :photo_path)))
      |> assign(:library_path, local_path(Map.get(assigns, :library_path)))

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

  @doc """
  Tells the timeline's browser hook which photo the page's address names, from the parent
  LiveView (usually in `handle_params/3`): `file_uuid` is that photo, or nil when the address
  names none, which closes the swipe viewer if it is open. `id` is the component's id, `scope`
  and `auth` are what it was given. A photo the viewer may not read is treated as none.

  The hook opens the viewer on the photo (or leaves one that already shows it alone), and does
  not change the address: it is already right.
  """
  @spec push_view(
          Phoenix.LiveView.Socket.t(),
          String.t(),
          Timeline.scope(),
          Scope.t() | nil,
          String.t() | nil
        ) ::
          Phoenix.LiveView.Socket.t()
  def push_view(socket, id, scope, auth, file_uuid) do
    payload =
      with uuid when is_binary(uuid) <- file_uuid,
           {:ok, position} <- Timeline.position(scope, uuid, auth) do
        %{id: uuid, global: position}
      else
        _ -> %{id: nil, global: nil}
      end

    Phoenix.LiveView.push_event(socket, "timeline:#{id}:view", payload)
  end

  @doc false
  # A path on the host's own site: one slash, then something that is not a second slash (which
  # would be another site) or a backslash, and no scheme. Nothing else reaches the page.
  def local_path("/" <> rest = path) when is_binary(path) do
    if String.starts_with?(rest, ["/", "\\"]) or String.contains?(path, ["\n", "\r", " "]),
      do: nil,
      else: path
  end

  def local_path(_path), do: nil

  @doc false
  # `photo_path` must say where the code goes.
  def photo_path(path) do
    path = local_path(path)
    if is_binary(path) and String.contains?(path, ":code"), do: path
  end

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

  defp validate_layout!(layout) when is_map_key(@layouts, layout), do: Map.fetch!(@layouts, layout)

  defp validate_layout!(other) do
    raise ArgumentError,
          "PhotoTimeline :layout must be one of #{inspect(Map.keys(@layouts))}, " <>
            "got: #{inspect(other)}"
  end

  # What the menu offers: every style, or the host's list in the order of the menu.
  defp offered_styles(true), do: @styles

  defp offered_styles(list) when is_list(list) do
    wanted = Enum.map(list, &Map.get(@layouts, &1))
    Enum.filter(@styles, &(&1 in wanted))
  end

  defp offered_styles(_none), do: []

  defp style_label("grid"), do: gettext("Grid")
  defp style_label("rows"), do: gettext("Rows")
  defp style_label("columns"), do: gettext("Columns")
  defp style_label("mosaic"), do: gettext("Mosaic")
  defp style_label("whole"), do: gettext("Uncropped")
  defp style_label("feed"), do: gettext("Feed")
  defp style_label("prints"), do: gettext("Prints")
  defp style_label("film"), do: gettext("Film")
  defp style_label("honeycomb"), do: gettext("Honeycomb")
  defp style_label("details"), do: gettext("Details")

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

      {socket, aspects} = changed_aspects(socket)

      push_event(socket, event(socket, "index"), %{
        revision: socket.assigns.revision,
        library: library_uuid,
        total: index.total,
        sections: Enum.map(index.sections, &section_payload/1),
        metrics: %{cell: 160, gap: socket.assigns.gap, header: 40},
        aspects: aspects
      })
    else
      socket
    end
  end

  # The aspect ratios of the sections the browser does not have yet, or that changed since it
  # last got them. A burst of uploads changes one month, not the library. Nil until asked for.
  defp changed_aspects(%{assigns: %{aspects_wanted: false}} = socket), do: {socket, nil}

  defp changed_aspects(socket) do
    case Timeline.aspects(socket.assigns.scope, socket.assigns.auth) do
      {:ok, aspects} ->
        sent = Map.new(aspects, fn {id, bytes} -> {id, :erlang.phash2(bytes)} end)
        before = socket.assigns.aspects_sent

        changed =
          for {id, bytes} <- aspects, sent[id] != before[id], into: %{} do
            {id, Base.encode64(bytes)}
          end

        {assign(socket, :aspects_sent, sent), changed}

      {:error, _reason} ->
        {socket, nil}
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
  # A hook saying hello has nothing yet, whatever this process sent an earlier one.
  def handle_event("timeline:ready", params, socket) do
    {:noreply,
     socket
     |> assign(:aspects_wanted, params["aspects"] == true or socket.assigns.aspects_wanted)
     |> assign(:aspects_sent, %{})
     |> load_index()}
  end

  # A style that shows whole photos was picked: from now on the index brings the ratios.
  def handle_event("timeline:aspects", %{"revision" => revision}, socket) do
    {socket, aspects} = socket |> assign(:aspects_wanted, true) |> changed_aspects()

    {:noreply,
     push_event(socket, event(socket, "aspects"), %{aspects: aspects || %{}, revision: revision})}
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
            kind: item.kind,
            fit: item.fit,
            large: item.large,
            name: item.name,
            size: item.size,
            duration: item.duration
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
      data-photo-path={@photo_path}
      data-library-path={@library_path}
    >
      <%!-- The month, and the choice of style. Filling the screen they float under the header
           as pills. --%>
      <div
        :if={@sections != []}
        class={[
          "flex items-center gap-2",
          @fill && "absolute right-3 z-10",
          !@fill && "justify-end"
        ]}
        style={@fill && "top: calc(var(--photo-timeline-inset-top, 0px) + 0.5rem)"}
      >
        <div :if={@styles != []} id={"#{@id}-styles"} class="relative" phx-update="ignore">
          <button
            type="button"
            data-style-toggle
            aria-haspopup="true"
            aria-expanded="false"
            aria-label={gettext("Change how photos are shown")}
            title={gettext("Change how photos are shown (V)")}
            class="flex cursor-pointer items-center gap-1 rounded-full border border-base-content/10 bg-base-100/50 py-1.5 pl-2.5 pr-2 shadow-sm backdrop-blur-md"
          >
            <span data-style-current class="block h-[18px] w-6"></span>
            <span class="hero-chevron-down size-4 opacity-60" aria-hidden="true"></span>
          </button>
          <div
            data-style-menu
            hidden
            class="absolute right-0 top-full z-20 mt-2 w-[min(21rem,calc(100vw-1.5rem))] rounded-box border border-base-content/10 bg-base-100/90 p-2 shadow-xl backdrop-blur-xl [&:not([hidden])]:grid grid-cols-3 gap-1 sm:grid-cols-4"
          >
            <button
              :for={style <- @styles}
              type="button"
              data-style-pick={style}
              aria-pressed="false"
              class="flex cursor-pointer flex-col items-center gap-1.5 rounded-field px-1 py-2 text-xs transition-colors hover:bg-base-content/5 aria-pressed:bg-primary/15 aria-pressed:text-primary"
            >
              <.style_glyph style={style} />
              <span>{style_label(style)}</span>
            </button>
          </div>
        </div>

        <form
          :if={!@fill}
          id={"#{@id}-jump"}
          phx-change="timeline:jump"
          phx-auto-recover="ignore"
          phx-target={@myself}
        >
          <select name="id" class="select select-bordered select-sm" aria-label="Jump to month">
            <option :for={section <- @sections} value={section.id}>{section.label}</option>
          </select>
        </form>

        <%!-- The invisible select over the pill is the list; the browser's own picker opens,
             which is the right one on a phone. --%>
        <form
          :if={@fill}
          id={"#{@id}-jump"}
          phx-change="timeline:jump"
          phx-auto-recover="ignore"
          phx-target={@myself}
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
      </div>

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
        data-style={@layout}
        class={[
          "phoenix-kit-photo-timeline__viewport relative touch-pan-y overflow-y-auto",
          @fill && "h-full overscroll-contain",
          !@fill && "h-[70vh]"
        ]}
      >
        <div class="phoenix-kit-photo-timeline__spacer"></div>
        <%!-- `[transform:translateZ(0)]` gives the layer of tiles a compositing layer
             of its own. The viewport is a nested scroller, and WebKit (iPadOS 26,
             checked 2026-10-26) paints an HDR photo in one as SDR unless the
             picture or a box around it is composited on its own. The hook's pinch
             zoom sets an inline transform while it runs and clears it after, so
             this one is back in force at rest. --%>
        <div class="phoenix-kit-photo-timeline__layer pointer-events-none absolute inset-x-0 top-0 [transform:translateZ(0)]"></div>
      </div>
    </div>
    """
  end

  attr :style, :string, required: true

  # A little picture of each style, for the menu.
  defp style_glyph(assigns) do
    assigns = assign(assigns, :shapes, glyph(assigns.style))

    ~H"""
    <svg viewBox="0 0 24 18" class="h-[18px] w-6" fill="currentColor" aria-hidden="true">
      <%= for {shape, attrs} <- @shapes do %>
        <rect :if={shape == :rect} {attrs} />
        <circle :if={shape == :circle} {attrs} />
      <% end %>
    </svg>
    """
  end

  defp box(x, y, w, h, extra), do: {:rect, [x: x, y: y, width: w, height: h] ++ extra}

  defp glyph("grid") do
    for x <- [0, 8.5, 17], y <- [0, 6.5, 13], do: box(x, y, 7, 5, rx: 0.8)
  end

  defp glyph("rows") do
    [
      box(0, 0, 9, 5.2, rx: 0.8),
      box(10, 0, 6, 5.2, rx: 0.8),
      box(17, 0, 7, 5.2, rx: 0.8),
      box(0, 6.4, 5, 5.2, rx: 0.8),
      box(6, 6.4, 11, 5.2, rx: 0.8),
      box(18, 6.4, 6, 5.2, rx: 0.8),
      box(0, 12.8, 13, 5.2, rx: 0.8),
      box(14, 12.8, 10, 5.2, rx: 0.8)
    ]
  end

  defp glyph("columns") do
    [
      box(0, 0, 7, 8, rx: 1),
      box(0, 9, 7, 9, rx: 1),
      box(8.5, 0, 7, 5, rx: 1),
      box(8.5, 6, 7, 12, rx: 1),
      box(17, 0, 7, 11, rx: 1),
      box(17, 12, 7, 6, rx: 1)
    ]
  end

  defp glyph("mosaic") do
    [
      box(0, 0, 11, 11, rx: 1.2),
      box(12.5, 0, 5, 5, rx: 1),
      box(19, 0, 5, 11, rx: 1),
      box(12.5, 6, 5, 5, rx: 1),
      box(0, 12.5, 5, 5.5, rx: 1),
      box(6.5, 12.5, 17.5, 5.5, rx: 1)
    ]
  end

  defp glyph("whole") do
    [
      box(0.5, 2, 7, 4.5, rx: 0.4),
      box(10, 0, 4, 7, rx: 0.4),
      box(16.5, 2, 7, 4, rx: 0.4),
      box(1.5, 11, 5, 7, rx: 0.4),
      box(8.5, 12, 7, 4.5, rx: 0.4),
      box(16.5, 12, 7, 5, rx: 0.4)
    ]
  end

  defp glyph("feed") do
    [box(5, 0, 14, 10.5, rx: 1.6), box(5, 12, 14, 6, rx: 1.6)]
  end

  defp glyph("prints") do
    [
      box(1, 1.5, 9, 11, rx: 0.5, transform: "rotate(-6 5.5 7)"),
      box(13.5, 0.5, 9, 11, rx: 0.5, transform: "rotate(5 18 6)", opacity: "0.7"),
      box(7.5, 7, 9, 11, rx: 0.5, transform: "rotate(2 12 12.5)", opacity: "0.85")
    ]
  end

  defp glyph("film") do
    holes = for x <- [1, 5, 9, 13, 17, 21], y <- [1, 15.5], do: box(x, y, 2, 1.5, rx: 0.3)
    frames = for x <- [0.5, 8.5, 16.5], do: box(x, 4, 7, 10, rx: 0.5)
    holes ++ frames
  end

  defp glyph("honeycomb") do
    for {x, y} <- [{4, 3.5}, {12, 3.5}, {20, 3.5}, {8, 10}, {16, 10}, {4, 16.5}, {12, 16.5}, {20, 16.5}] do
      {:circle, [cx: x, cy: y, r: 3.3]}
    end
  end

  defp glyph("details") do
    for y <- [0, 6.5, 13] do
      [box(0, y, 5, 5, rx: 0.8), box(7, y + 0.5, 17, 1.8, rx: 0.9), box(7, y + 3, 10, 1.4, rx: 0.7, opacity: "0.6")]
    end
    |> List.flatten()
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
