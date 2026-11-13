defmodule PhoenixKitPhotos.Components.InfoPanel do
  @moduledoc """
  The swipe viewer's info panel: what a photo is called and what it shows, when and where
  it was taken, its comments, and for someone who may change it, all of that to edit.

  It sits beside the photo on a wide screen and as a sheet under it on a phone, and it
  follows the viewer: turn the page and it shows the next photo. The `PhotoTimeline` hook
  opens and closes it (the Info button, `i`), and tells `PhotoTimeline` which photo is on
  screen, which hands it here as `file_uuid`. Everything it shows comes from
  `PhoenixKitPhotos.Details.load/4`, which decides what this person may see, and every
  change goes through `PhoenixKitPhotos.Details`, which checks again.

  ## Usage (from `PhotoTimeline`)

      <.live_component module={InfoPanel} id={"\#{@id}-info"} scope={@scope} auth={@auth}
        timeline_id={@id} />

      send_update(InfoPanel, id: "\#{id}-info", file_uuid: uuid)

  A change that moves a photo in time tells the timeline (`{:info_moved, file_uuid}` via
  `send_update/3` to `PhotoTimeline`), so the grid behind and the viewer follow the photo
  to its new place.
  """

  use Phoenix.LiveComponent
  use Gettext, backend: PhoenixKitPhotos.Gettext

  # Optional: the comments come from `phoenix_kit_comments` when the host has it.
  @compile {:no_warn_undefined, [PhoenixKitComments, PhoenixKitComments.Web.CommentsComponent]}

  alias Phoenix.LiveView.JS
  alias PhoenixKit.Modules.Languages
  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKitPhotos.{Details, Places}

  @impl true
  def mount(socket) do
    {:ok,
     socket
     |> assign(:file_uuid, nil)
     |> assign(:details, nil)
     |> assign(:editing, nil)
     |> assign(:error, nil)
     |> assign(:saved, nil)
     |> assign(:results, nil)
     |> assign(:query, "")
     |> assign(:pin, nil)
     |> assign(:suggestion, nil)
     |> assign(:languages_open, false)}
  end

  @impl true
  def update(%{file_uuid: uuid} = assigns, socket) do
    socket = assign_context(socket, assigns)

    if uuid == socket.assigns.file_uuid and socket.assigns.details != nil do
      {:ok, socket}
    else
      {:ok, socket |> assign(:file_uuid, uuid) |> reset_editing() |> load()}
    end
  end

  # The photo changed elsewhere (another tab, a person beside you): read it again, unless
  # this person is in the middle of changing it.
  def update(%{reload: true} = assigns, socket) do
    touched = assigns[:file_uuids]

    cond do
      is_nil(socket.assigns.details) -> {:ok, socket}
      socket.assigns.editing -> {:ok, socket}
      is_list(touched) and socket.assigns.file_uuid not in touched -> {:ok, socket}
      true -> {:ok, load(socket)}
    end
  end

  def update(%{clear_saved: part}, socket) do
    if socket.assigns.saved == part,
      do: {:ok, assign(socket, :saved, nil)},
      else: {:ok, socket}
  end

  def update(assigns, socket), do: {:ok, assign_context(socket, assigns)}

  defp assign_context(socket, assigns) do
    socket
    |> assign(:id, assigns[:id] || socket.assigns[:id])
    |> assign(:scope, Map.get(assigns, :scope, socket.assigns[:scope]))
    |> assign(:auth, Map.get(assigns, :auth, socket.assigns[:auth]))
    |> assign(:timeline_id, Map.get(assigns, :timeline_id, socket.assigns[:timeline_id]))
  end

  defp reset_editing(socket) do
    assign(socket,
      editing: nil,
      error: nil,
      saved: nil,
      results: nil,
      query: "",
      pin: nil,
      suggestion: nil,
      languages_open: false
    )
  end

  defp load(%{assigns: %{file_uuid: nil}} = socket), do: assign(socket, :details, nil)

  defp load(socket) do
    %{scope: scope, file_uuid: uuid, auth: auth} = socket.assigns

    case Details.load(scope, uuid, auth, Languages.request_locale()) do
      {:ok, details} ->
        socket
        |> assign(:details, details)
        |> look_up_name(details)

      {:error, _} ->
        assign(socket, :details, nil)
    end
  end

  # A place whose name is not known yet is named in the background.
  defp look_up_name(socket, %{place: %{lookup: {lat, lon, lang, detail}}, file_uuid: uuid}) do
    start_async(socket, :place_name, fn -> {uuid, Places.name(lat, lon, lang, detail)} end)
  end

  defp look_up_name(socket, _details), do: socket

  @impl true
  def handle_async(:place_name, {:ok, {uuid, name}}, socket) do
    case socket.assigns.details do
      %{file_uuid: ^uuid, place: %{} = place} = details when is_binary(name) ->
        {:noreply,
         assign(socket, :details, %{details | place: %{place | name: name, lookup: nil}})}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_async(:place_name, _result, socket), do: {:noreply, socket}

  def handle_async(:pin_name, {:ok, {pin, name}}, socket) do
    if socket.assigns.pin == pin and is_binary(name),
      do: {:noreply, assign(socket, :pin, Map.put(pin, :name, name))},
      else: {:noreply, socket}
  end

  def handle_async(:pin_name, _result, socket), do: {:noreply, socket}

  # ---------------------------------------------------------------------------
  # Events

  @impl true
  def handle_event("edit", %{"part" => part}, socket) when part in ~w(text date place) do
    case socket.assigns.details do
      %{editor?: true} = details ->
        socket = socket |> reset_editing() |> assign(:editing, part)

        socket =
          if part == "place" and is_nil(details.place[:latitude]),
            do:
              assign(
                socket,
                :suggestion,
                Details.suggest_place(socket.assigns.scope, details.file, socket.assigns.auth)
              ),
            else: socket

        {:noreply, socket}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("edit", _params, socket), do: {:noreply, socket}

  def handle_event("cancel", _params, socket), do: {:noreply, reset_editing(socket)}

  def handle_event("toggle_languages", _params, socket),
    do: {:noreply, update(socket, :languages_open, &(!&1))}

  def handle_event("save_text", %{"details" => %{} = by_lang}, socket) do
    %{scope: scope, file_uuid: uuid, auth: auth} = socket.assigns

    case Details.save_text(scope, uuid, by_lang, auth) do
      {:ok, _file} ->
        socket = socket |> reset_editing() |> load() |> saved(:text)
        title = socket.assigns.details && socket.assigns.details.text.title
        {:noreply, push_event(socket, "photos:retitle", %{id: uuid, title: title})}

      {:error, message} ->
        {:noreply, assign(socket, :error, message)}
    end
  end

  def handle_event("save_text", _params, socket), do: {:noreply, socket}

  def handle_event("save_date", params, socket) do
    %{scope: scope, file_uuid: uuid, auth: auth} = socket.assigns

    case Details.set_date(scope, uuid, params["date"], params["time"], auth) do
      {:ok, _uuids} -> {:noreply, socket |> reset_editing() |> load() |> saved(:date) |> moved()}
      {:error, message} -> {:noreply, assign(socket, :error, message)}
    end
  end

  def handle_event("reset_date", _params, socket) do
    %{scope: scope, file_uuid: uuid, auth: auth} = socket.assigns

    case Details.reset_date(scope, uuid, auth) do
      {:ok, _uuids} -> {:noreply, socket |> reset_editing() |> load() |> saved(:date) |> moved()}
      {:error, message} -> {:noreply, assign(socket, :error, message)}
    end
  end

  def handle_event("place_search", %{"q" => query}, socket) do
    lang = socket.assigns.details && socket.assigns.details.lang

    case Places.search(query, lang) do
      {:ok, results} ->
        {:noreply, assign(socket, results: results, query: query, error: nil)}

      {:error, :busy} ->
        {:noreply,
         assign(socket,
           query: query,
           error: gettext("The map search is busy. Try again in a moment.")
         )}

      {:error, _} ->
        {:noreply,
         assign(socket, query: query, error: gettext("The map search could not be reached."))}
    end
  end

  # A spot chosen on the map (a click, or the pin dragged): shown, and named in the
  # background, until it is saved.
  def handle_event("place_pin", %{"lat" => lat, "lon" => lon}, socket)
      when is_number(lat) and is_number(lon) do
    pin = %{latitude: lat, longitude: lon, name: nil}
    lang = socket.assigns.details && socket.assigns.details.lang

    {:noreply,
     socket
     |> assign(:pin, pin)
     |> start_async(:pin_name, fn -> {pin, Places.name(lat, lon, lang, :exact)} end)}
  end

  def handle_event("place_pin", _params, socket), do: {:noreply, socket}

  def handle_event("place_pick", %{"lat" => lat, "lon" => lon} = params, socket) do
    with {lat, _} <- Float.parse(to_string(lat)),
         {lon, _} <- Float.parse(to_string(lon)) do
      save_place(socket, {lat, lon}, params["name"])
    else
      _ -> {:noreply, assign(socket, :error, Details.message(:invalid_position))}
    end
  end

  def handle_event("place_save_pin", _params, socket) do
    case socket.assigns.pin do
      %{latitude: lat, longitude: lon, name: name} -> save_place(socket, {lat, lon}, name)
      _ -> {:noreply, socket}
    end
  end

  def handle_event("place_clear", _params, socket) do
    %{scope: scope, file_uuid: uuid, auth: auth} = socket.assigns

    case Details.clear_place(scope, uuid, auth) do
      {:ok, _} -> {:noreply, socket |> reset_editing() |> load() |> saved(:place)}
      {:error, message} -> {:noreply, assign(socket, :error, message)}
    end
  end

  def handle_event("place_reset", _params, socket) do
    %{scope: scope, file_uuid: uuid, auth: auth} = socket.assigns

    case Details.reset_place(scope, uuid, auth) do
      {:ok, _} -> {:noreply, socket |> reset_editing() |> load() |> saved(:place)}
      {:error, message} -> {:noreply, assign(socket, :error, message)}
    end
  end

  defp save_place(socket, position, name) do
    %{scope: scope, file_uuid: uuid, auth: auth} = socket.assigns

    case Details.set_place(scope, uuid, position, name, auth) do
      {:ok, _} -> {:noreply, socket |> reset_editing() |> load() |> saved(:place)}
      {:error, message} -> {:noreply, assign(socket, :error, message)}
    end
  end

  # "Saved" by what was saved, for a moment.
  defp saved(socket, part) do
    send_update_after(__MODULE__, [id: socket.assigns.id, clear_saved: part], 2_500)
    assign(socket, :saved, part)
  end

  # The photo moved in time: the timeline reads its index again and the viewer follows it.
  defp moved(socket) do
    if id = socket.assigns.timeline_id do
      send_update(PhoenixKitPhotos.Components.PhotoTimeline,
        id: id,
        info_moved: socket.assigns.file_uuid
      )
    end

    socket
  end

  # ---------------------------------------------------------------------------
  # Rendering

  @impl true
  def render(assigns) do
    assigns =
      assigns
      |> assign(:user, Scope.user(assigns.auth))
      |> assign(:comments?, comments_enabled?())

    ~H"""
    <aside
      id={@id}
      popover="manual"
      data-theme="dark"
      data-info-panel
      phx-mounted={JS.ignore_attributes(["style"])}
      aria-label={gettext("About this photo")}
      class="pk-info-panel m-0 overflow-y-auto overscroll-contain border-0 bg-base-100/95 p-0 text-base-content shadow-2xl backdrop-blur-xl"
    >
      <div class="sticky top-0 z-10 flex items-center gap-2 border-b border-base-content/10 bg-base-100/90 px-4 py-2.5 backdrop-blur-xl">
        <span class="pk-info-grip" aria-hidden="true"></span>
        <h2 class="flex-1 text-sm font-semibold">{gettext("Info")}</h2>
        <button
          type="button"
          class="btn btn-ghost btn-sm btn-circle"
          phx-click={JS.dispatch("photos:info-close")}
          aria-label={gettext("Close the info panel")}
          title={gettext("Close (I)")}
        >
          <span class="hero-x-mark size-5" aria-hidden="true"></span>
        </button>
      </div>

      <div :if={is_nil(@details)} class="p-6 text-sm text-base-content/60" aria-busy="true">
        <span class="loading loading-dots loading-sm"></span>
      </div>

      <div :if={@details} class="space-y-1 pb-10">
        <p :if={@error} class="mx-4 mt-3 rounded-box bg-error/15 px-3 py-2 text-sm text-error" role="alert">
          {@error}
        </p>

        <.text_section details={@details} editing={@editing} saved={@saved} myself={@myself}
          id={@id} languages_open={@languages_open} />
        <.date_section details={@details} editing={@editing} saved={@saved} myself={@myself} id={@id} />
        <.place_section details={@details} editing={@editing} saved={@saved} myself={@myself}
          id={@id} results={@results} query={@query} pin={@pin} suggestion={@suggestion} />
        <.facts_section details={@details} myself={@myself} />

        <section
          :if={@comments? and @details.comments != :none}
          class="pk-info-comments mx-4 mt-4 border-t border-base-content/10 pt-4"
          aria-label={gettext("Comments")}
        >
          <.live_component
            module={PhoenixKitComments.Web.CommentsComponent}
            id={"#{@id}-comments-#{@details.file_uuid}"}
            resource_type="file"
            resource_uuid={@details.file_uuid}
            current_user={if @details.comments == :write, do: @user}
            pk_scope={if @details.comments == :write, do: @auth}
            rich_text={false}
            show_likes={true}
            composer_position={if @details.comments == :write, do: :bottom}
            title={gettext("Comments")}
          />
        </section>
      </div>
    </aside>
    """
  end

  # --- what it is called ------------------------------------------------------

  attr :details, :map, required: true
  attr :editing, :string
  attr :saved, :atom
  attr :myself, :any, required: true
  attr :id, :string, required: true
  attr :languages_open, :boolean

  defp text_section(%{editing: "text"} = assigns) do
    [first | others] = assigns.details.languages
    assigns = assign(assigns, first: first, others: others)

    ~H"""
    <form
      id={"#{@id}-text-form"}
      class="space-y-2 px-4 pt-4"
      phx-submit="save_text"
      phx-target={@myself}
      phx-keydown="cancel"
      phx-key="Escape"
    >
      <.language_fields lang={@first} own={@details.own[@first.code]} id={@id} autofocus
        tagged={@others != []} />

      <button
        :if={@others != []}
        type="button"
        class="btn btn-ghost btn-xs gap-1 px-1"
        phx-click="toggle_languages"
        phx-target={@myself}
        aria-expanded={to_string(@languages_open)}
      >
        <span class={["size-4", if(@languages_open, do: "hero-chevron-up", else: "hero-language")]} aria-hidden="true"></span>
        {if @languages_open, do: gettext("Hide other languages"), else: gettext("Other languages")}
        <span :if={!@languages_open} class="text-base-content/50">
          ({@others |> Enum.map(& &1.short) |> Enum.join(", ")})
        </span>
      </button>

      <div :for={lang <- @others} class={["space-y-2 rounded-box bg-base-content/5 p-3", !@languages_open && "hidden"]}>
        <.language_fields lang={lang} own={@details.own[lang.code]} id={@id} tagged />
      </div>

      <div class="flex items-center gap-2 pt-1">
        <button type="submit" class="btn btn-primary btn-sm">{gettext("Save")}</button>
        <button type="button" class="btn btn-ghost btn-sm" phx-click="cancel" phx-target={@myself}>
          {gettext("Cancel")}
        </button>
      </div>
    </form>
    """
  end

  defp text_section(assigns) do
    ~H"""
    <section class="group relative px-4 pt-4" aria-label={gettext("Title and description")}>
      <h3
        :if={@details.text.title}
        class="pr-8 text-lg font-semibold leading-snug break-words"
      >
        {@details.text.title}
      </h3>
      <p
        :if={@details.text.description}
        class="mt-1 pr-8 text-sm leading-relaxed whitespace-pre-line break-words text-base-content/80"
      >{String.trim(@details.text.description)}</p>
      <p :if={@details.text.from} class="mt-1 text-xs text-base-content/50">
        {gettext("Written in %{language}", language: @details.text.from)}
      </p>

      <button
        :if={@details.editor? and is_nil(@details.text.title) and is_nil(@details.text.description)}
        type="button"
        class="flex w-full cursor-pointer items-center gap-2 rounded-box border border-dashed border-base-content/20 px-3 py-3 text-left text-sm text-base-content/60 transition hover:border-primary/60 hover:text-base-content"
        phx-click="edit"
        phx-value-part="text"
        phx-target={@myself}
      >
        <span class="hero-pencil-square size-5" aria-hidden="true"></span>
        {gettext("Add a title and a description")}
      </button>

      <button
        :if={@details.editor? and (@details.text.title || @details.text.description)}
        type="button"
        class="btn btn-ghost btn-xs btn-circle absolute right-3 top-4 opacity-60 hover:opacity-100"
        phx-click="edit"
        phx-value-part="text"
        phx-target={@myself}
        aria-label={gettext("Edit the title and description")}
        title={gettext("Edit")}
      >
        <span class="hero-pencil size-4" aria-hidden="true"></span>
      </button>
      <.saved_mark :if={@saved == :text} />
    </section>
    """
  end

  attr :lang, :map, required: true
  attr :own, :map, required: true
  attr :id, :string, required: true
  attr :autofocus, :boolean, default: false
  attr :tagged, :boolean, default: false

  defp language_fields(assigns) do
    ~H"""
    <div class="space-y-2">
      <div :if={@tagged} class="flex items-center gap-2 text-xs font-medium text-base-content/60">
        <span class="badge badge-sm badge-ghost">{@lang.short}</span>
        <span>{@lang.name}</span>
      </div>
      <input
        id={"#{@id}-title-#{@lang.code}"}
        name={"details[#{@lang.code}][title]"}
        value={@own["title"]}
        placeholder={gettext("Title")}
        aria-label={gettext("Title")}
        maxlength="255"
        autocomplete="off"
        phx-mounted={@autofocus && JS.focus()}
        class="input input-sm w-full text-base font-semibold"
      />
      <textarea
        id={"#{@id}-description-#{@lang.code}"}
        name={"details[#{@lang.code}][description]"}
        placeholder={gettext("What is in this photo? Who, where, why it matters…")}
        aria-label={gettext("Description")}
        maxlength="5000"
        rows="4"
        class="textarea textarea-sm w-full leading-relaxed [field-sizing:content] min-h-24"
      >{@own["description"]}</textarea>
      <input
        id={"#{@id}-alt-#{@lang.code}"}
        name={"details[#{@lang.code}][alt]"}
        value={@own["alt"]}
        placeholder={gettext("Alt text: the photo in words, for people who cannot see it")}
        aria-label={gettext("Alt text")}
        maxlength="500"
        autocomplete="off"
        class="input input-xs w-full"
      />
    </div>
    """
  end

  # --- when -------------------------------------------------------------------

  attr :details, :map, required: true
  attr :editing, :string
  attr :saved, :atom
  attr :myself, :any, required: true
  attr :id, :string, required: true

  defp date_section(%{editing: "date"} = assigns) do
    ~H"""
    <form
      id={"#{@id}-date-form"}
      class="mx-4 mt-4 space-y-2 border-t border-base-content/10 pt-4"
      phx-submit="save_date"
      phx-target={@myself}
      phx-keydown="cancel"
      phx-key="Escape"
    >
      <div class="flex items-center gap-2 text-sm font-medium">
        <span class="hero-calendar-days size-5 text-base-content/60" aria-hidden="true"></span>
        {if @details.stack, do: gettext("When this stack was taken"), else: gettext("When it was taken")}
      </div>
      <div class="flex gap-2">
        <input
          type="date"
          name="date"
          value={@details.date.date_value}
          min="1826-01-01"
          required
          phx-mounted={JS.focus()}
          aria-label={gettext("Date")}
          class="input input-sm flex-1"
        />
        <input
          type="time"
          name="time"
          value={@details.date.time_value}
          aria-label={gettext("Time")}
          class="input input-sm w-28"
        />
      </div>
      <p :if={@details.stack} class="text-xs text-base-content/60">
        {ngettext(
          "The stack's photo moves with it.",
          "All %{count} photos of the stack move together, keeping their order and the time between them.",
          @details.stack.count
        )}
      </p>
      <p class="text-xs text-base-content/50">
        {gettext("The library shows photos in the order they were taken, so this moves it there.")}
      </p>
      <div class="flex flex-wrap items-center gap-2 pt-1">
        <button type="submit" class="btn btn-primary btn-sm">{gettext("Save")}</button>
        <button type="button" class="btn btn-ghost btn-sm" phx-click="cancel" phx-target={@myself}>
          {gettext("Cancel")}
        </button>
        <button
          :if={@details.date.manual?}
          type="button"
          class="btn btn-link btn-sm ml-auto px-0"
          phx-click="reset_date"
          phx-target={@myself}
        >
          {if @details.stack, do: gettext("Use the photos' own dates"), else: gettext("Use the photo's own date")}
        </button>
      </div>
    </form>
    """
  end

  defp date_section(assigns) do
    ~H"""
    <section class="relative mx-4 mt-4 border-t border-base-content/10 pt-4" aria-label={gettext("Date")}>
      <button
        type="button"
        disabled={!@details.editor?}
        class={[
          "flex w-full items-start gap-3 rounded-box text-left",
          @details.editor? && "-mx-2 cursor-pointer px-2 py-1 transition hover:bg-base-content/5"
        ]}
        phx-click="edit"
        phx-value-part="date"
        phx-target={@myself}
        title={@details.editor? && gettext("Change the date")}
      >
        <span class="hero-calendar-days mt-0.5 size-5 shrink-0 text-base-content/60" aria-hidden="true"></span>
        <span class="min-w-0 flex-1">
          <span class="block text-sm font-medium">{@details.date.label}</span>
          <span class="block text-xs text-base-content/60">
            {@details.date.time}<span :if={@details.date.zone}> · {@details.date.zone}</span><span :if={@details.date.source_label}> · {@details.date.source_label}</span>
          </span>
          <span :if={@details.stack} class="mt-0.5 block text-xs text-base-content/50">
            {ngettext("The date of a stack of %{count} photo", "The date of a stack of %{count} photos", @details.stack.count)}
          </span>
        </span>
        <span :if={@details.editor?} class="hero-pencil mt-1 size-4 shrink-0 opacity-50" aria-hidden="true"></span>
      </button>
      <.saved_mark :if={@saved == :date} />
    </section>
    """
  end

  # --- where ------------------------------------------------------------------

  attr :details, :map, required: true
  attr :editing, :string
  attr :saved, :atom
  attr :myself, :any, required: true
  attr :id, :string, required: true
  attr :results, :list
  attr :query, :string
  attr :pin, :map
  attr :suggestion, :map

  defp place_section(%{editing: "place"} = assigns) do
    place = assigns.details.place || %{}

    center =
      cond do
        assigns.pin -> {assigns.pin.latitude, assigns.pin.longitude, 15}
        is_number(place[:latitude]) -> {place.latitude, place.longitude, 14}
        assigns.suggestion -> {assigns.suggestion.latitude, assigns.suggestion.longitude, 12}
        true -> nil
      end

    assigns = assign(assigns, place: place, center: center)

    ~H"""
    <section class="mx-4 mt-4 space-y-2 border-t border-base-content/10 pt-4" aria-label={gettext("Where it was taken")}>
      <div class="flex items-center gap-2 text-sm font-medium">
        <span class="hero-map-pin size-5 text-base-content/60" aria-hidden="true"></span>
        {gettext("Where it was taken")}
      </div>

      <form
        :if={Places.enabled?()}
        id={"#{@id}-place-search"}
        class="join w-full"
        phx-submit="place_search"
        phx-target={@myself}
        phx-keydown="cancel"
        phx-key="Escape"
      >
        <input
          name="q"
          value={@query}
          type="search"
          placeholder={gettext("Search for a place or an address")}
          aria-label={gettext("Search for a place")}
          autocomplete="off"
          phx-mounted={JS.focus()}
          class="input input-sm join-item flex-1"
        />
        <button type="submit" class="btn btn-sm join-item" aria-label={gettext("Search")}>
          <span class="hero-magnifying-glass size-4" aria-hidden="true"></span>
        </button>
      </form>

      <ul :if={@results != nil} class="menu menu-sm w-full rounded-box bg-base-content/5 p-1">
        <li :if={@results == []} class="px-3 py-2 text-xs text-base-content/60">
          {gettext("Nothing found. Try other words, or click the map.")}
        </li>
        <li :for={result <- @results}>
          <button
            type="button"
            phx-click="place_pick"
            phx-value-lat={result.latitude}
            phx-value-lon={result.longitude}
            phx-value-name={result.name}
            phx-target={@myself}
            class="items-start text-left"
          >
            <span class="hero-map-pin mt-0.5 size-4 shrink-0 opacity-60" aria-hidden="true"></span>
            <span class="min-w-0">
              <span class="block truncate font-medium">{result.name}</span>
              <span :if={result[:full] && result.full != result.name} class="block truncate text-xs opacity-60">
                {result.full}
              </span>
            </span>
          </button>
        </li>
      </ul>

      <button
        :if={@suggestion && is_nil(@pin)}
        type="button"
        phx-click="place_pick"
        phx-value-lat={@suggestion.latitude}
        phx-value-lon={@suggestion.longitude}
        phx-value-name={@suggestion.name}
        phx-target={@myself}
        class="flex w-full cursor-pointer items-center gap-2 rounded-box bg-primary/10 px-3 py-2 text-left text-sm transition hover:bg-primary/20"
      >
        <span class="hero-sparkles size-4 shrink-0 text-primary" aria-hidden="true"></span>
        <span class="min-w-0">
          <span class="block font-medium">{gettext("Same place as a photo taken near then")}</span>
          <span :if={@suggestion.name} class="block truncate text-xs text-base-content/60">{@suggestion.name}</span>
        </span>
      </button>

      <.place_map
        id={"#{@id}-map-edit-#{@details.file_uuid}"}
        latitude={(@pin && @pin.latitude) || @place[:latitude]}
        longitude={(@pin && @pin.longitude) || @place[:longitude]}
        center={@center}
        editable
        target={@myself}
        class="h-56"
      />
      <p class="text-xs text-base-content/50">{gettext("Click the map to put the pin there, or drag it.")}</p>

      <div :if={@pin} class="flex items-center gap-2 rounded-box bg-base-content/5 px-3 py-2 text-sm">
        <span class="hero-map-pin size-4 text-primary" aria-hidden="true"></span>
        <span class="min-w-0 flex-1 truncate">
          {@pin.name || coordinates(@pin.latitude, @pin.longitude)}
        </span>
        <button type="button" class="btn btn-primary btn-xs" phx-click="place_save_pin" phx-target={@myself}>
          {gettext("Save this place")}
        </button>
      </div>

      <div class="flex flex-wrap items-center gap-2 pt-1">
        <button type="button" class="btn btn-ghost btn-sm" phx-click="cancel" phx-target={@myself}>
          {gettext("Cancel")}
        </button>
        <button
          :if={is_number(@place[:latitude])}
          type="button"
          class="btn btn-ghost btn-sm text-error"
          phx-click="place_clear"
          phx-target={@myself}
        >
          {gettext("Remove the place")}
        </button>
        <button
          :if={@place[:manual?] and @place[:exif?]}
          type="button"
          class="btn btn-link btn-sm ml-auto px-0"
          phx-click="place_reset"
          phx-target={@myself}
        >
          {gettext("Use the camera's place")}
        </button>
      </div>
    </section>
    """
  end

  defp place_section(%{details: %{place: nil}} = assigns), do: ~H""

  defp place_section(%{details: %{place: %{view: :missing}}} = assigns) do
    ~H"""
    <section class="mx-4 mt-4 border-t border-base-content/10 pt-4" aria-label={gettext("Where it was taken")}>
      <button
        :if={@details.editor?}
        type="button"
        class="flex w-full cursor-pointer items-center gap-3 rounded-box border border-dashed border-base-content/20 px-3 py-3 text-left text-sm text-base-content/60 transition hover:border-primary/60 hover:text-base-content"
        phx-click="edit"
        phx-value-part="place"
        phx-target={@myself}
      >
        <span class="hero-map-pin size-5" aria-hidden="true"></span>
        <span>
          {gettext("Add where it was taken")}
          <span :if={@details.place.manual? and @details.place.exif?} class="block text-xs">
            {gettext("Its place was removed by hand.")}
          </span>
        </span>
      </button>
      <.saved_mark :if={@saved == :place} />
    </section>
    """
  end

  defp place_section(assigns) do
    ~H"""
    <section class="relative mx-4 mt-4 border-t border-base-content/10 pt-4" aria-label={gettext("Where it was taken")}>
      <div class="flex items-start gap-3">
        <span class="hero-map-pin mt-0.5 size-5 shrink-0 text-base-content/60" aria-hidden="true"></span>
        <div class="min-w-0 flex-1">
          <p class="text-sm font-medium break-words">
            <span :if={@details.place.view == :area}>{gettext("Near")} </span>{@details.place.name || coordinates(@details.place.latitude, @details.place.longitude, @details.place.view)}
          </p>
          <p :if={place_note(@details.place) != ""} class="text-xs text-base-content/60">
            {place_note(@details.place)}
          </p>
          <p
            :if={@details.audience == :member and @details.place.shared != "everyone"}
            class="mt-0.5 flex items-center gap-1 text-xs text-base-content/50"
          >
            <span class="hero-lock-closed size-3" aria-hidden="true"></span>
            {if @details.place.shared == "area",
              do: gettext("Others see only the area"),
              else: gettext("Only members see this")}
          </p>
        </div>
        <button
          :if={@details.editor?}
          type="button"
          class="btn btn-ghost btn-xs btn-circle opacity-60 hover:opacity-100"
          phx-click="edit"
          phx-value-part="place"
          phx-target={@myself}
          aria-label={gettext("Change the place")}
          title={gettext("Change the place")}
        >
          <span class="hero-pencil size-4" aria-hidden="true"></span>
        </button>
      </div>

      <.place_map
        id={"#{@id}-map-#{@details.file_uuid}"}
        latitude={@details.place.latitude}
        longitude={@details.place.longitude}
        radius={@details.place.radius}
        class="mt-3 h-40"
      />
      <a
        :if={@details.place.view == :exact}
        href={"https://www.openstreetmap.org/?mlat=#{@details.place.latitude}&mlon=#{@details.place.longitude}#map=16/#{@details.place.latitude}/#{@details.place.longitude}"}
        target="_blank"
        rel="noopener noreferrer"
        class="link link-hover mt-1 inline-flex items-center gap-1 text-xs text-base-content/60"
      >
        {gettext("Open in a map")}
        <span class="hero-arrow-top-right-on-square size-3" aria-hidden="true"></span>
      </a>
      <.saved_mark :if={@saved == :place} />
    </section>
    """
  end

  attr :id, :string, required: true
  attr :latitude, :any, default: nil
  attr :longitude, :any, default: nil
  attr :radius, :any, default: nil
  attr :center, :any, default: nil
  attr :editable, :boolean, default: false
  attr :target, :any, default: nil
  attr :class, :string, default: ""

  defp place_map(assigns) do
    assigns = assign(assigns, :tiles, Places.tiles())

    ~H"""
    <div
      id={@id}
      phx-hook="PhotoPlaceMap"
      phx-update="ignore"
      phx-target={@target}
      data-lat={@latitude}
      data-lon={@longitude}
      data-radius={@radius}
      data-center={@center && Enum.join(Tuple.to_list(@center), ",")}
      data-default-center={default_center()}
      data-editable={to_string(@editable)}
      data-tiles={@tiles.url}
      data-attribution={@tiles.attribution}
      class={["pk-place-map w-full overflow-hidden rounded-box bg-base-300", @class]}
      role="img"
      aria-label={gettext("Map")}
    >
    </div>
    """
  end

  # --- the file ---------------------------------------------------------------

  attr :details, :map, required: true
  attr :myself, :any, required: true

  defp facts_section(assigns) do
    ~H"""
    <section class="mx-4 mt-4 border-t border-base-content/10 pt-4" aria-label={gettext("File")}>
      <div class="flex items-start gap-3">
        <span
          class={[
            "mt-0.5 size-5 shrink-0 text-base-content/60",
            if(@details.facts.type == "video", do: "hero-film", else: "hero-photo")
          ]}
          aria-hidden="true"
        >
        </span>
        <div class="min-w-0 flex-1 text-xs leading-relaxed text-base-content/70">
          <p class="truncate text-sm font-medium text-base-content" title={@details.facts.name}>
            {@details.facts.name}
          </p>
          <p>
            <span :if={@details.facts.width && @details.facts.height}>
              {@details.facts.width} × {@details.facts.height}
              <span :if={@details.facts.type == "image"}>· {megapixels(@details.facts)} MP</span>
            </span>
            <span :if={@details.facts.duration}> · {duration(@details.facts.duration)}</span>
            <span :if={@details.facts.size}> · {file_size(@details.facts.size)}</span>
          </p>
          <p :if={@details.facts.camera}>{@details.facts.camera}</p>
          <p :if={@details.facts.exposure}>{@details.facts.exposure}</p>
        </div>
      </div>
      <button
        type="button"
        class="btn btn-ghost btn-xs mt-2 gap-1 px-1 text-base-content/60"
        phx-click={JS.dispatch("photos:info-more", detail: %{id: @details.file_uuid})}
      >
        <span class="hero-information-circle size-4" aria-hidden="true"></span>
        {gettext("All details")}
      </button>
    </section>
    """
  end

  defp saved_mark(assigns) do
    ~H"""
    <span
      class="pk-info-saved pointer-events-none absolute right-12 top-4 flex items-center gap-1 text-xs text-success"
      role="status"
    >
      <span class="hero-check-circle size-4" aria-hidden="true"></span>{gettext("Saved")}
    </span>
    """
  end

  # ---------------------------------------------------------------------------

  defp comments_enabled? do
    Code.ensure_loaded?(PhoenixKitComments) and PhoenixKitComments.enabled?()
  rescue
    _ -> false
  end

  defp default_center do
    case Application.get_env(:phoenix_kit_photos, :map_default_center) do
      {lat, lon, zoom} -> "#{lat},#{lon},#{zoom}"
      _ -> "30,10,2"
    end
  end

  # The line under a place's name: its coordinates when the name is above them, that only
  # the area is shown, that it was set by hand.
  defp place_note(place) do
    [
      (place.view == :exact and place.name) && coordinates(place.latitude, place.longitude),
      place.view == :area && gettext("Only the area is shown"),
      place.manual? && gettext("Set by hand")
    ]
    |> Enum.filter(&is_binary/1)
    |> Enum.join(" · ")
  end

  @doc false
  def coordinates(lat, lon, view \\ :exact)

  def coordinates(lat, lon, view) when is_number(lat) and is_number(lon) do
    digits = if view == :area, do: 2, else: 5
    "#{degrees(lat, digits, "N", "S")}, #{degrees(lon, digits, "E", "W")}"
  end

  def coordinates(_lat, _lon, _view), do: ""

  defp degrees(value, digits, positive, negative) do
    hemisphere = if value < 0, do: negative, else: positive
    "#{:erlang.float_to_binary(abs(value * 1.0), decimals: digits)}° #{hemisphere}"
  end

  defp megapixels(%{width: w, height: h}) when is_integer(w) and is_integer(h),
    do: :erlang.float_to_binary(w * h / 1_000_000, decimals: 1)

  defp megapixels(_facts), do: ""

  defp duration(seconds) when is_integer(seconds) do
    "#{div(seconds, 60)}:#{String.pad_leading(to_string(rem(seconds, 60)), 2, "0")}"
  end

  defp duration(_), do: ""

  defp file_size(bytes) when is_integer(bytes) and bytes >= 1_048_576,
    do: :erlang.float_to_binary(bytes / 1_048_576, decimals: 1) <> " MB"

  defp file_size(bytes) when is_integer(bytes) and bytes >= 1024, do: "#{div(bytes, 1024)} KB"
  defp file_size(bytes) when is_integer(bytes), do: "#{bytes} B"
  defp file_size(_), do: ""
end
