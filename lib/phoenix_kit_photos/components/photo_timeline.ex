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

  ## Choosing many

  `selectable` lets a person choose photos, and act on them from a bar along the bottom. How
  they choose is in `assets/js/selection.js`: the circle on a tile, Shift + click, a box
  dragged with the mouse, hold and slide on a touch screen, the circle on a month, Ctrl/Cmd + A,
  and the "Select" menu of the bar (the day, the moment, every video). The ids stay in the
  browser until an action is asked for; then every file is checked again on the server
  (`PhoenixKitPhotos.Bulk`), the person sees what would happen, and it runs in the background
  with a progress bar. Trash can be undone from the notice that follows it.

  `download_path` is where `PhoenixKitPhotos.Web.Download` is mounted; without it there is no
  Download. Copy links needs `photo_path`.

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

  alias PhoenixKit.Modules.Storage.Libraries
  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKitPhotos.Bulk
  alias PhoenixKitPhotos.Timeline
  alias PhoenixKitPhotos.Uploads

  @styles ~w(grid rows columns mosaic whole feed prints film honeycomb details)
  @layouts Map.new(@styles, &{String.to_atom(&1), &1}) |> Map.put(:square, "grid")

  @impl true
  def mount(socket) do
    {:ok,
     socket
     |> assign(:aspects_wanted, false)
     |> assign(:aspects_sent, %{})
     |> assign(:bulk, nil)
     |> assign(:running, nil)
     |> assign(:notice, nil)
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

  # From the process running a bulk action.
  def update(%{bulk_progress: {done, total}}, socket) do
    {:ok, assign(socket, :running, %{done: done, total: total})}
  end

  def update(%{bulk_done: result}, socket) do
    {:ok, finish_bulk(socket, result)}
  end

  def update(%{dismiss_notice: ref}, socket) do
    {:ok,
     if(match?(%{ref: ^ref}, socket.assigns.notice),
       do: assign(socket, :notice, nil),
       else: socket
     )}
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
      |> assign(:selectable, Map.get(assigns, :selectable, false) == true)
      |> assign(:download_path, local_path(Map.get(assigns, :download_path)))
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

  defp validate_layout!(layout) when is_map_key(@layouts, layout),
    do: Map.fetch!(@layouts, layout)

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

  # `hello: true` marks the index that answers a hook's `timeline:ready`: the one an address may
  # open the viewer in. An index sent before it (with the page) has a revision this process has
  # already left, so every window asked for from it would be refused.
  defp load_index(socket, opts \\ []) do
    socket = assign(socket, :revision, socket.assigns.revision + 1)

    case Timeline.index(socket.assigns.scope, socket.assigns.auth) do
      {:ok, index} ->
        socket
        |> assign(:index, index)
        |> assign(:sections, index.sections)
        |> assign(:state, index.state)
        |> assign(:error, nil)
        |> assign(:loaded_for, {socket.assigns.scope, socket.assigns.auth})
        |> push_index(index, Keyword.get(opts, :hello, false))

      {:error, reason} ->
        socket
        |> assign(:index, nil)
        |> assign(:sections, [])
        |> assign(:state, :error)
        |> assign(:error, reason)
        |> assign(:loaded_for, {socket.assigns.scope, socket.assigns.auth})
    end
  end

  defp push_index(socket, index, hello?) do
    if connected?(socket) do
      {:library, library_uuid} = socket.assigns.scope

      {socket, aspects} = changed_aspects(socket)

      push_event(socket, event(socket, "index"), %{
        hello: hello?,
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
     |> load_index(hello: true)}
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

  # A run of positions, for a selection that goes through what the browser has not fetched.
  def handle_event("timeline:range", %{"revision" => revision} = params, socket) do
    if socket.assigns.selectable and revision == socket.assigns.revision do
      opts = [
        from: integer(params["from"]),
        to: integer(params["to"]),
        kind: params["kind"],
        limit: Bulk.limit()
      ]

      case Timeline.ids_between(socket.assigns.scope, socket.assigns.auth, opts) do
        {:ok, ids, capped} ->
          {:noreply,
           push_event(socket, event(socket, "range"), %{
             ids: ids,
             mode: range_mode(params["mode"]),
             capped: capped,
             revision: revision
           })}

        {:error, _reason} ->
          {:noreply, socket}
      end
    else
      {:noreply, socket}
    end
  end

  # An action on what is chosen: first what would happen, for the person to say yes to.
  def handle_event("timeline:bulk", %{"action" => name, "ids" => ids}, socket)
      when is_list(ids) do
    action = Bulk.action(name)

    # A download never comes this way: it is a form post of its own.
    allowed = menu_actions(socket) -- [:download]

    if socket.assigns.selectable and action in allowed and !socket.assigns.running do
      {:noreply, open_bulk(socket, action, ids)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("timeline:bulk", _params, socket), do: {:noreply, socket}

  # The choices of the dialog changed: the plan is made again for them.
  def handle_event("timeline:bulk_change", params, socket) do
    case socket.assigns.bulk do
      %{action: action, ids: ids} = bulk ->
        plan = Bulk.plan(action, ids, socket.assigns.auth, params)
        {:noreply, assign(socket, :bulk, %{bulk | plan: plan, params: params})}

      nil ->
        {:noreply, socket}
    end
  end

  def handle_event("timeline:bulk_cancel", _params, socket) do
    {:noreply, assign(socket, :bulk, nil)}
  end

  # The person said yes. What runs is planned again now, not what the dialog was opened on: the
  # rights or the files may have changed since.
  def handle_event("timeline:bulk_run", params, socket) do
    case socket.assigns.bulk do
      %{action: action, ids: ids} when action != :links ->
        plan = Bulk.plan(action, ids, socket.assigns.auth, params)
        {:noreply, socket |> assign(:bulk, nil) |> start_run(plan)}

      _other ->
        {:noreply, socket}
    end
  end

  def handle_event("timeline:bulk_undo", _params, socket) do
    case socket.assigns.notice do
      %{undo: ids} when ids != [] ->
        plan = Bulk.plan(:restore, ids, socket.assigns.auth)
        {:noreply, socket |> assign(:notice, nil) |> start_run(plan)}

      _other ->
        {:noreply, socket}
    end
  end

  def handle_event("timeline:notice_close", _params, socket) do
    {:noreply, assign(socket, :notice, nil)}
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

  defp integer(value) when is_integer(value) and value >= 0, do: value
  defp integer(_value), do: nil

  defp range_mode(mode) when mode in ["add", "remove", "toggle"], do: mode
  defp range_mode(_mode), do: "add"

  # What the bar offers this person in this library. It is a courtesy: `Bulk` decides per file.
  defp menu_actions(%{assigns: assigns}) do
    {:library, library_uuid} = assigns.scope
    signed_in = is_binary(assigns.auth && Scope.user_uuid(assigns.auth))
    editor = signed_in and Uploads.can_upload?(assigns.auth, library_uuid)

    [
      assigns.download_path && :download,
      assigns.photo_path && :links,
      signed_in && :copy,
      editor && :move,
      editor && :tag,
      editor && :trash
    ]
    |> Enum.filter(& &1)
  end

  defp open_bulk(socket, :links, ids) do
    plan = Bulk.plan(:links, ids, socket.assigns.auth)
    template = socket.assigns.photo_path

    paths =
      for %{short_code: code} <- plan.files, is_binary(code) do
        String.replace(template, ":code", URI.encode(code))
      end

    socket
    |> assign(:bulk, %{action: :links, ids: ids, plan: plan, params: %{}, targets: []})
    |> push_event(event(socket, "links"), %{paths: paths})
  end

  defp open_bulk(socket, action, ids) do
    targets = targets(socket, action)
    params = default_params(action, targets)
    plan = Bulk.plan(action, ids, socket.assigns.auth, params)

    assign(socket, :bulk, %{
      action: action,
      ids: ids,
      plan: plan,
      params: params,
      targets: targets
    })
  end

  defp default_params(action, [first | _]) when action in [:copy, :move],
    do: %{"library" => first.uuid}

  defp default_params(_action, _targets), do: %{}

  # The other libraries this person may add to.
  defp targets(socket, action) when action in [:copy, :move] do
    {:library, here} = socket.assigns.scope
    auth = socket.assigns.auth

    auth
    |> Timeline.libraries()
    |> Enum.filter(&(&1.uuid != here and Uploads.can_upload?(auth, &1.uuid)))
    |> Enum.reject(&(Libraries.managed?(&1) or Libraries.hidden?(&1)))
  end

  defp targets(_socket, _action), do: []

  # Runs apart from the page: leaving the page does not stop a bulk action halfway.
  defp start_run(socket, %{files: []} = plan) do
    finish_bulk(socket, %{action: plan.action, done: [], failed: plan.refused, created: []})
  end

  defp start_run(socket, plan) do
    page = self()
    id = socket.assigns.id
    total = length(plan.files)
    # A hundred steps at most, however many files.
    every = max(1, div(total, 100))

    Task.start(fn ->
      progress = fn done, total ->
        if rem(done, every) == 0 do
          Phoenix.LiveView.send_update(page, __MODULE__, id: id, bulk_progress: {done, total})
        end
      end

      # Whatever happens, the page hears of it: a bar that never ends locks the bulk actions.
      result =
        try do
          Bulk.run(plan, on_progress: progress)
        rescue
          _error -> failed_run(plan)
        catch
          _kind, _reason -> failed_run(plan)
        end

      result = %{result | failed: plan.refused ++ result.failed}
      Phoenix.LiveView.send_update(page, __MODULE__, id: id, bulk_done: result)
    end)

    assign(socket, :running, %{done: 0, total: total})
  end

  defp failed_run(plan) do
    failed = Enum.map(plan.files, &%{id: &1.uuid, name: nil, reason: :failed})
    %{action: plan.action, done: [], failed: failed, created: []}
  end

  defp finish_bulk(socket, %{action: action, done: done} = result) do
    ref = make_ref()

    Phoenix.LiveView.send_update_after(
      __MODULE__,
      [id: socket.assigns.id, dismiss_notice: ref],
      9_000
    )

    socket
    |> assign(:running, nil)
    |> assign(:notice, %{
      ref: ref,
      text: outcome_text(action, length(done)),
      problems: problems(result.failed),
      undo: if(action == :trash, do: done, else: [])
    })
    |> push_event(event(socket, "selection"), %{clear: true})
  end

  defp outcome_text(:trash, count),
    do: ngettext("Moved 1 item to the trash", "Moved %{count} items to the trash", count)

  defp outcome_text(:restore, count),
    do: ngettext("Restored 1 item", "Restored %{count} items", count)

  defp outcome_text(:copy, count),
    do: ngettext("Copied 1 item", "Copied %{count} items", count)

  defp outcome_text(:move, count),
    do: ngettext("Moved 1 item", "Moved %{count} items", count)

  defp outcome_text(:tag, count),
    do: ngettext("Tagged 1 item", "Tagged %{count} items", count)

  # A line for each reason something was left out: nobody reads a list of two hundred files.
  defp problems(failed) do
    failed
    |> Enum.frequencies_by(& &1.reason)
    |> Enum.map(fn {reason, count} -> "#{count}: #{Bulk.reason_text(reason)}" end)
  end

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
            code: item.code,
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
      data-download-path={@download_path}
      data-select-month-label={gettext("Select this month")}
      data-selection-limit={Bulk.limit()}
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
        <button
          :if={@selectable}
          id={"#{@id}-select"}
          type="button"
          data-select-start
          title={gettext("Select photos")}
          class="cursor-pointer rounded-full border border-base-content/10 bg-base-100/50 px-3 py-1.5 text-sm font-medium shadow-sm backdrop-blur-md"
        >
          {gettext("Select")}
        </button>

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
        data-styles={Enum.join(@styles, " ")}
        data-selectable={to_string(@selectable)}
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

      <.selection_bar
        :if={@selectable && !@error}
        id={"#{@id}-selection-#{elem(@scope, 1)}"}
        actions={menu_actions(%{assigns: assigns})}
      />
      <.bulk_dialog :if={@bulk} bulk={@bulk} myself={@myself} id={@id} />
      <.bulk_progress :if={@running} running={@running} />
      <.bulk_notice :if={@notice && !@running} notice={@notice} myself={@myself} />
    </div>
    """
  end

  attr :id, :string, required: true
  attr :actions, :list, required: true

  # Shown and counted by the hook, which is why LiveView keeps its hands off it. The id carries
  # the library: another library means other rights, and a new bar.
  defp selection_bar(assigns) do
    ~H"""
    <div
      id={@id}
      data-selection-bar
      hidden
      phx-update="ignore"
      class="pointer-events-none fixed inset-x-0 bottom-0 z-30 flex justify-center px-3 pb-[max(0.75rem,env(safe-area-inset-bottom))]"
    >
      <div class="pointer-events-auto flex max-w-full flex-wrap items-center justify-center gap-1 rounded-2xl border border-base-content/10 bg-base-100/90 p-1.5 shadow-xl backdrop-blur-xl">
        <button
          type="button"
          data-select="none"
          aria-label={gettext("Clear selection")}
          title={gettext("Clear selection (Esc)")}
          class="btn btn-ghost btn-circle btn-sm"
        >
          <span class="hero-x-mark size-5" aria-hidden="true"></span>
        </button>
        <span class="whitespace-nowrap px-1 text-sm font-medium tabular-nums">
          <span data-selection-count>0</span> {gettext("selected")}
          <span data-selection-capped hidden class="text-warning">
            ({gettext("the most at once")})
          </span>
        </span>
        <details class="dropdown dropdown-top">
          <summary class="btn btn-ghost btn-sm font-normal">
            {gettext("Select")}<span class="hero-chevron-up size-3.5" aria-hidden="true"></span>
          </summary>
          <ul class="menu dropdown-content z-40 mb-2 w-56 rounded-box border border-base-content/10 bg-base-100 p-1 shadow-xl">
            <li><button type="button" data-select="moment">{gettext("This moment")}</button></li>
            <li><button type="button" data-select="day">{gettext("This day")}</button></li>
            <li><button type="button" data-select="videos">{gettext("All videos")}</button></li>
            <li><button type="button" data-select="photos">{gettext("All photos")}</button></li>
            <li><button type="button" data-select="all">{gettext("Everything")}</button></li>
          </ul>
        </details>
        <span class="mx-0.5 h-5 w-px bg-base-content/15" aria-hidden="true"></span>
        <button
          :for={action <- @actions}
          type="button"
          data-bulk={action}
          disabled
          title={bulk_label(action)}
          class={[
            "btn btn-ghost btn-sm gap-1.5 px-2 font-normal",
            action == :trash && "text-error"
          ]}
        >
          <span class={[bulk_icon(action), "size-5"]} aria-hidden="true"></span>
          <span class="hidden lg:inline">{bulk_label(action)}</span>
        </button>
      </div>
    </div>
    """
  end

  defp bulk_label(:download), do: gettext("Download")
  defp bulk_label(:links), do: gettext("Copy links")
  defp bulk_label(:copy), do: gettext("Add to library")
  defp bulk_label(:move), do: gettext("Move")
  defp bulk_label(:tag), do: gettext("Tags")
  defp bulk_label(:trash), do: gettext("Trash")

  defp bulk_icon(:download), do: "hero-arrow-down-tray"
  defp bulk_icon(:links), do: "hero-link"
  defp bulk_icon(:copy), do: "hero-document-duplicate"
  defp bulk_icon(:move), do: "hero-arrow-right-circle"
  defp bulk_icon(:tag), do: "hero-tag"
  defp bulk_icon(:trash), do: "hero-trash"

  attr :bulk, :map, required: true
  attr :myself, :any, required: true
  attr :id, :string, required: true

  # What is about to happen, for the person to agree to.
  defp bulk_dialog(assigns) do
    assigns =
      assigns
      |> assign(:count, length(assigns.bulk.plan.files))
      |> assign(:refused, problems(assigns.bulk.plan.refused))

    ~H"""
    <div class="modal modal-open z-50" role="dialog" aria-modal="true">
      <form
        id={"#{@id}-bulk"}
        class="modal-box max-w-md"
        phx-change="timeline:bulk_change"
        phx-submit="timeline:bulk_run"
        phx-target={@myself}
      >
        <h3 class="text-lg font-bold">{dialog_title(@bulk.action, @count)}</h3>
        <p :if={dialog_hint(@bulk.action)} class="mt-2 text-sm text-base-content/70">
          {dialog_hint(@bulk.action)}
        </p>

        <label :if={@bulk.action in [:copy, :move] && @bulk.targets != []} class="mt-4 block">
          <span class="mb-1 block text-sm">{gettext("Library")}</span>
          <select name="library" class="select select-bordered w-full">
            <option
              :for={library <- @bulk.targets}
              value={library.uuid}
              selected={library.uuid == @bulk.params["library"]}
            >
              {library.name}
            </option>
          </select>
        </label>
        <p :if={@bulk.action in [:copy, :move] && @bulk.targets == []} class="mt-4 text-sm">
          {gettext("You have no other library to add these to.")}
        </p>

        <div :if={@bulk.action == :tag} class="mt-4 space-y-3">
          <label class="block">
            <span class="mb-1 block text-sm">{gettext("Add tags (separate with commas)")}</span>
            <input
              name="add"
              value={@bulk.params["add"]}
              class="input input-bordered w-full"
              maxlength="400"
              autocomplete="off"
            />
          </label>
          <label class="block">
            <span class="mb-1 block text-sm">{gettext("Remove tags")}</span>
            <input
              name="remove"
              value={@bulk.params["remove"]}
              class="input input-bordered w-full"
              maxlength="400"
              autocomplete="off"
            />
          </label>
        </div>

        <textarea
          :if={@bulk.action == :links}
          id={"#{@id}-links"}
          data-links
          phx-update="ignore"
          readonly
          rows="6"
          class="textarea textarea-bordered mt-4 w-full font-mono text-xs"
        ></textarea>

        <ul :if={@refused != []} class="mt-4 space-y-1 text-sm text-warning">
          <li :for={line <- @refused}>{line}</li>
        </ul>

        <div class="modal-action">
          <button
            type="button"
            class="btn btn-ghost"
            phx-click="timeline:bulk_cancel"
            phx-target={@myself}
          >
            {if @bulk.action == :links, do: gettext("Close"), else: gettext("Cancel")}
          </button>
          <button
            :if={@bulk.action == :links}
            type="button"
            data-copy-links
            data-done={gettext("Copied")}
            class="btn btn-primary"
          >
            {gettext("Copy")}
          </button>
          <button
            :if={@bulk.action != :links}
            type="submit"
            disabled={@count == 0 or not ready?(@bulk)}
            class={["btn", (@bulk.action == :trash && "btn-error") || "btn-primary"]}
          >
            {dialog_confirm(@bulk.action)}
          </button>
        </div>
      </form>
      <button
        type="button"
        class="modal-backdrop"
        aria-label={gettext("Close")}
        phx-click="timeline:bulk_cancel"
        phx-target={@myself}
      >
      </button>
    </div>
    """
  end

  defp ready?(%{action: :tag, plan: plan}), do: plan.add != [] or plan.remove != []
  defp ready?(_bulk), do: true

  defp dialog_title(:trash, count),
    do: ngettext("Move 1 item to the trash?", "Move %{count} items to the trash?", count)

  defp dialog_title(:copy, count),
    do: ngettext("Add 1 item to a library", "Add %{count} items to a library", count)

  defp dialog_title(:move, count),
    do: ngettext("Move 1 item to a library", "Move %{count} items to a library", count)

  defp dialog_title(:tag, count), do: ngettext("Tag 1 item", "Tag %{count} items", count)

  defp dialog_title(:links, count),
    do: ngettext("Link to 1 photo", "Links to %{count} photos", count)

  defp dialog_hint(:trash), do: gettext("You can bring them back from the trash.")
  defp dialog_hint(:move), do: gettext("The originals go to the trash of this library.")
  defp dialog_hint(:links), do: gettext("Only people who may see the library can open them.")
  defp dialog_hint(_action), do: nil

  defp dialog_confirm(:trash), do: gettext("Move to trash")
  defp dialog_confirm(:copy), do: gettext("Add")
  defp dialog_confirm(:move), do: gettext("Move")
  defp dialog_confirm(:tag), do: gettext("Save tags")

  attr :running, :map, required: true

  defp bulk_progress(assigns) do
    ~H"""
    <div class="pointer-events-none fixed inset-x-0 bottom-0 z-40 flex justify-center px-3 pb-[max(0.75rem,env(safe-area-inset-bottom))]">
      <div
        class="flex w-full max-w-sm items-center gap-3 rounded-2xl border border-base-content/10 bg-base-100/95 p-3 shadow-xl backdrop-blur-xl"
        role="status"
      >
        <span class="text-sm tabular-nums">{@running.done} / {@running.total}</span>
        <progress class="progress progress-primary flex-1" value={@running.done} max={@running.total}>
        </progress>
      </div>
    </div>
    """
  end

  attr :notice, :map, required: true
  attr :myself, :any, required: true

  defp bulk_notice(assigns) do
    ~H"""
    <div class="pointer-events-none fixed inset-x-0 bottom-0 z-40 flex justify-center px-3 pb-[max(0.75rem,env(safe-area-inset-bottom))]">
      <div
        class="pointer-events-auto flex max-w-md items-center gap-3 rounded-2xl border border-base-content/10 bg-base-100/95 px-4 py-2.5 shadow-xl backdrop-blur-xl"
        role="status"
      >
        <div class="min-w-0 text-sm">
          <p class="font-medium">{@notice.text}</p>
          <p :for={line <- @notice.problems} class="text-warning">{line}</p>
        </div>
        <button
          :if={@notice.undo != []}
          type="button"
          class="btn btn-ghost btn-sm"
          phx-click="timeline:bulk_undo"
          phx-target={@myself}
        >
          {gettext("Undo")}
        </button>
        <button
          type="button"
          class="btn btn-ghost btn-circle btn-xs"
          aria-label={gettext("Close")}
          phx-click="timeline:notice_close"
          phx-target={@myself}
        >
          <span class="hero-x-mark size-4" aria-hidden="true"></span>
        </button>
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
    for {x, y} <- [
          {4, 3.5},
          {12, 3.5},
          {20, 3.5},
          {8, 10},
          {16, 10},
          {4, 16.5},
          {12, 16.5},
          {20, 16.5}
        ] do
      {:circle, [cx: x, cy: y, r: 3.3]}
    end
  end

  defp glyph("details") do
    for y <- [0, 6.5, 13] do
      [
        box(0, y, 5, 5, rx: 0.8),
        box(7, y + 0.5, 17, 1.8, rx: 0.9),
        box(7, y + 3, 10, 1.4, rx: 0.7, opacity: "0.6")
      ]
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
