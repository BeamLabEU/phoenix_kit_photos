defmodule PhoenixKitPhotos.Components.LinkFetcher do
  @moduledoc """
  Fetching from a link, in a library: the dialog a pasted link opens and the cards of
  the person's fetches into this library (`PhoenixKitPhotos.Fetches`).

      <.live_component
        module={PhoenixKitPhotos.Components.LinkFetcher}
        id="link-fetcher"
        library_uuid={library_uuid}
        auth={scope}
        logins_path="/profile/settings/fetches"
        open={@params["fetch"]}
      />

  It shows nothing to someone who may not add to the library, or where fetching is off
  (`Fetches.available?/0`). `open` (a fetch's uuid, the page's `?fetch=` parameter)
  opens that fetch's dialog, for the person's list of fetches to link to.

  ## How a link arrives

    * **Pasted** anywhere on the page but in a text field (the `LinkFetcher` hook,
      `link_fetcher.js`).
    * From the uploader's **From a link** field, or its Paste button on an iPad
      (`PhotoUploader`'s `link_fetcher` attribute names this component).
    * `send_update(LinkFetcher, id: id, start: text)` from anywhere else.

  ## The dialog

  It opens on the link at once, says it is being looked at, then shows what was found:
  title, author, date, the entries of an album or playlist (each can be unticked), the
  quality for a video, and **the confirmation of the right to keep a copy**, unticked:
  *Fetch* stays disabled until it is ticked, and the server refuses without it
  (`Fetches.confirm/3`). Closing it keeps the link as a card ("Review and fetch");
  *Forget* drops it.

  ## The cards

  They float in the library's bottom-left corner (the uploader's + is bottom right).
  One per fetch of the person's into this library that is not dismissed: being looked
  at, waiting for them, waiting its turn, running (with a progress bar), or how it
  ended. They are read from the database and then follow the fetch over PubSub
  (`PhoenixKitPhotos.LiveUpdates.watch_fetches/3`), so a refresh or a lost connection
  loses nothing. The page needs the `LiveUpdates` hook for the cards to move.
  """

  use Phoenix.LiveComponent
  use Gettext, backend: PhoenixKitPhotos.Gettext

  import PhoenixKitWeb.Components.Core.Icon, only: [icon: 1]
  import PhoenixKitPhotos.Components.FetchCards, only: [card: 1, bytes: 1, duration: 1]

  alias PhoenixKit.Modules.Storage.Libraries
  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKitPhotos.{Fetches, LiveUpdates, Uploads}
  alias PhoenixKitPhotos.Fetches.Fetch

  @impl true
  def mount(socket) do
    {:ok,
     assign(socket,
       fetches: [],
       waiting: %{},
       open: nil,
       form: %{},
       notice: nil,
       library: nil,
       library_uuid: nil,
       enabled: false,
       logins_path: nil,
       opened_param: nil
     )}
  end

  @impl true
  def update(%{fetch_event: {:fetch, %Fetch{} = fetch}}, socket) do
    if to_string(fetch.library_uuid) == socket.assigns.library_uuid do
      {:ok, socket |> put_fetch(fetch) |> follow_dialog(fetch)}
    else
      {:ok, socket}
    end
  end

  def update(%{fetch_event: {:removed, uuid}}, socket) do
    uuid = to_string(uuid)

    {:ok,
     socket
     |> assign(:fetches, Enum.reject(socket.assigns.fetches, &(to_string(&1.uuid) == uuid)))
     |> then(&if(&1.assigns.open == uuid, do: close(&1), else: &1))}
  end

  def update(%{start: text}, socket), do: {:ok, start(socket, text)}

  def update(assigns, socket) do
    library_uuid = to_string(assigns.library_uuid)
    auth = assigns[:auth]
    enabled = Fetches.available?() and Uploads.can_upload?(auth, library_uuid)

    socket =
      socket
      |> assign(:id, assigns.id)
      |> assign(:auth, auth)
      |> assign(:logins_path, assigns[:logins_path])
      |> assign(:library_uuid, library_uuid)
      |> assign(:enabled, enabled)

    socket =
      if enabled do
        if connected?(socket),
          do: LiveUpdates.watch_fetches(__MODULE__, assigns.id, Scope.user_uuid(auth))

        library = Uploads.library(library_uuid)

        socket
        |> assign(:library, library)
        |> assign(:public?, Libraries.published?(library))
        |> assign(:fetches, Fetches.for_library(auth, library_uuid))
        |> count_waiting()
        |> open_asked(assigns[:open])
      else
        assign(socket, fetches: [])
      end

    {:ok, socket}
  end

  # `open` (the page's `?fetch=` parameter): that fetch's dialog, once per value.
  defp open_asked(socket, uuid) when is_binary(uuid) and uuid != "" do
    if socket.assigns.opened_param == uuid do
      socket
    else
      socket = assign(socket, :opened_param, uuid)

      case Enum.find(socket.assigns.fetches, &(to_string(&1.uuid) == uuid)) do
        %Fetch{status: status} = fetch when status in ["probing", "ready", "unavailable"] ->
          open(socket, fetch)

        _ ->
          socket
      end
    end
  end

  defp open_asked(socket, _uuid), do: socket

  # ── Events ─────────────────────────────────────────────────────────────

  @impl true
  def handle_event("paste_link", %{"text" => text}, socket), do: {:noreply, start(socket, text)}

  def handle_event("open", %{"uuid" => uuid}, socket) do
    case Enum.find(socket.assigns.fetches, &(to_string(&1.uuid) == uuid)) do
      nil -> {:noreply, socket}
      fetch -> {:noreply, open(socket, fetch)}
    end
  end

  def handle_event("close", _params, socket), do: {:noreply, close(socket)}

  def handle_event("change", params, socket) do
    {:noreply, assign(socket, :form, form_from(params))}
  end

  def handle_event("select", %{"all" => all}, socket) do
    items =
      if all == "true",
        do: for(%{"index" => i} <- open_entries(socket), do: to_string(i)),
        else: []

    {:noreply, assign(socket, :form, Map.put(socket.assigns.form, "items", items))}
  end

  def handle_event("confirm", params, socket) do
    form = form_from(params)

    case Fetches.confirm(socket.assigns.auth, socket.assigns.open, form) do
      {:ok, fetch} ->
        {:noreply, socket |> put_fetch(fetch) |> close()}

      {:error, reason} ->
        {:noreply, socket |> assign(:form, form) |> assign(:notice, confirm_error(reason))}
    end
  end

  def handle_event("cancel", %{"uuid" => uuid}, socket) do
    case Fetches.cancel(socket.assigns.auth, uuid) do
      {:ok, :removed} ->
        {:noreply,
         socket
         |> assign(:fetches, Enum.reject(socket.assigns.fetches, &(to_string(&1.uuid) == uuid)))
         |> then(&if(&1.assigns.open == uuid, do: close(&1), else: &1))}

      {:ok, %Fetch{} = fetch} ->
        {:noreply, put_fetch(socket, fetch)}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("retry", %{"uuid" => uuid}, socket) do
    case Fetches.retry(socket.assigns.auth, uuid) do
      {:ok, %Fetch{status: "probing"} = fetch} ->
        {:noreply, socket |> put_fetch(fetch) |> open(fetch)}

      {:ok, fetch} ->
        {:noreply, put_fetch(socket, fetch)}

      {:error, reason} ->
        {:noreply, assign(socket, :notice, confirm_error(reason))}
    end
  end

  def handle_event("dismiss", %{"uuid" => uuid}, socket) do
    case Fetches.dismiss(socket.assigns.auth, uuid) do
      {:ok, _} ->
        {:noreply,
         assign(
           socket,
           :fetches,
           Enum.reject(socket.assigns.fetches, &(to_string(&1.uuid) == uuid))
         )}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("hide_notice", _params, socket), do: {:noreply, assign(socket, :notice, nil)}

  # ── State ──────────────────────────────────────────────────────────────

  defp start(%{assigns: %{enabled: false}} = socket, _text), do: socket

  defp start(socket, text) do
    case Fetches.start(socket.assigns.auth, socket.assigns.library_uuid, text) do
      {:ok, fetch} ->
        socket |> put_fetch(fetch) |> open(fetch)

      {:error, reason} ->
        assign(socket, :notice, start_error(reason))
    end
  end

  defp open(socket, %Fetch{} = fetch) do
    assign(socket, open: to_string(fetch.uuid), form: default_form(fetch), notice: nil)
  end

  defp close(socket), do: assign(socket, open: nil, form: %{}, notice: nil)

  # The dialog follows its fetch: the look's result fills it, and once confirmed the
  # fetch is a card and the dialog goes.
  defp follow_dialog(socket, %Fetch{} = fetch) do
    cond do
      socket.assigns.open != to_string(fetch.uuid) -> socket
      fetch.status in ["probing", "ready", "unavailable"] -> maybe_default_form(socket, fetch)
      true -> close(socket)
    end
  end

  defp maybe_default_form(socket, fetch) do
    if socket.assigns.form["items"] == nil and fetch.status == "ready",
      do: assign(socket, :form, default_form(fetch)),
      else: socket
  end

  defp put_fetch(socket, %Fetch{} = fetch) do
    others = Enum.reject(socket.assigns.fetches, &(&1.uuid == fetch.uuid))

    fetches =
      if Fetches.on_cards?(fetch),
        do: Enum.sort_by([fetch | others], & &1.inserted_at, NaiveDateTime),
        else: others

    socket |> assign(:fetches, fetches) |> count_waiting()
  end

  defp count_waiting(socket) do
    waiting =
      for %Fetch{status: "queued"} = fetch <- socket.assigns.fetches,
          into: %{},
          do: {fetch.uuid, Fetches.waiting_before(fetch)}

    assign(socket, :waiting, waiting)
  end

  defp default_form(%Fetch{status: "ready", info: info}) do
    %{
      "items" => for(%{"index" => i} <- info["entries"] || [], do: to_string(i)),
      "quality" => "default",
      "rights" => false
    }
  end

  defp default_form(_fetch), do: %{}

  defp form_from(params) do
    %{
      "items" => params |> Map.get("items", []) |> List.wrap() |> Enum.reject(&(&1 in ["", nil])),
      "quality" => if(params["quality"] == "best", do: "best", else: "default"),
      "rights" => params["rights"] in ["true", "on", true]
    }
  end

  defp open_fetch(%{assigns: %{open: nil}}), do: nil

  defp open_fetch(%{assigns: %{open: uuid, fetches: fetches}}),
    do: Enum.find(fetches, &(to_string(&1.uuid) == uuid))

  defp open_entries(socket) do
    case open_fetch(socket) do
      %Fetch{info: info} -> info["entries"] || []
      _ -> []
    end
  end

  defp start_error(:not_a_link),
    do: gettext("That is not a link to fetch from. Paste one link that starts with https://")

  defp start_error(:email_unconfirmed),
    do: gettext("Confirm your email address first: open the link you were sent.")

  defp start_error(:not_allowed), do: gettext("You may not add to this library.")
  defp start_error(_reason), do: gettext("Fetching from a link is not available right now.")

  defp confirm_error(:rights), do: gettext("Tick the box to confirm you may keep a copy.")
  defp confirm_error(:no_items), do: gettext("Choose at least one item to fetch.")
  defp confirm_error(:nothing_missing), do: gettext("Everything from this link is already here.")
  defp confirm_error(:not_ready), do: gettext("This link is not ready to fetch any more.")
  defp confirm_error(reason), do: start_error(reason)

  # ── Rendering ──────────────────────────────────────────────────────────

  @impl true
  def render(%{enabled: false} = assigns), do: ~H"<div id={@id} hidden></div>"

  def render(assigns) do
    assigns =
      assigns
      |> assign(:dialog_fetch, open_fetch(%{assigns: assigns}))
      # The fetch in the dialog is not a card behind it as well.
      |> assign(:cards, Enum.reject(assigns.fetches, &(to_string(&1.uuid) == assigns.open)))

    ~H"""
    <div id={@id} phx-hook="LinkFetcher" phx-target={@myself} data-link-fetcher>
      <%!-- The cards float over the library (bottom left; the uploader's + is bottom
           right), so a library that fills the screen keeps its layout. --%>
      <div
        :if={@cards != [] || (@notice && !@dialog_fetch)}
        id={"#{@id}-cards"}
        aria-label={gettext("Fetching from links")}
        class="fixed bottom-3 left-3 z-40 flex max-h-[45vh] w-[min(24rem,calc(100vw-5.5rem))] flex-col gap-2 overflow-y-auto sm:bottom-6 sm:left-6"
      >
        <div
          :if={@notice && !@dialog_fetch}
          id={"#{@id}-notice"}
          role="alert"
          class="alert alert-warning py-2 text-sm shadow-lg"
        >
          <span>{@notice}</span>
          <button type="button" phx-click="hide_notice" phx-target={@myself} class="btn btn-ghost btn-xs" aria-label={gettext("Close")}>
            <.icon name="hero-x-mark" class="h-4 w-4" />
          </button>
        </div>
        <.card :for={fetch <- @cards} fetch={fetch} target={@myself} waiting={Map.get(@waiting, fetch.uuid, 0)} />
      </div>

      <.dialog :if={@dialog_fetch} id={@id} fetch={@dialog_fetch} form={@form} notice={@notice} target={@myself} public?={@public?} logins_path={@logins_path} />
    </div>
    """
  end

  attr :id, :string, required: true
  attr :fetch, Fetch, required: true
  attr :form, :map, required: true
  attr :notice, :string, default: nil
  attr :target, :any, required: true
  attr :public?, :boolean, default: false
  attr :logins_path, :string, default: nil

  defp dialog(assigns) do
    assigns =
      assigns
      |> assign(:info, assigns.fetch.info || %{})
      |> assign(:picked, MapSet.new(assigns.form["items"] || []))

    ~H"""
    <dialog
      id={"#{@id}-dialog-#{@fetch.uuid}"}
      phx-mounted={Phoenix.LiveView.JS.ignore_attributes(["open"])}
      phx-hook="PhotoStackDialog"
      data-close="close"
      phx-target={@target}
      class="modal"
      aria-labelledby={"#{@id}-dialog-title"}
    >
      <form
        id={"#{@id}-dialog-form"}
        class="modal-box flex max-h-[90vh] max-w-2xl flex-col gap-3"
        phx-change="change"
        phx-submit="confirm"
        phx-target={@target}
      >
        <div class="flex items-start justify-between gap-2">
          <div class="min-w-0">
            <h3 id={"#{@id}-dialog-title"} class="text-lg font-bold">{gettext("Fetch from a link")}</h3>
            <a href={@fetch.url} target="_blank" rel="noopener noreferrer nofollow" class="link link-hover block truncate text-sm text-base-content/70">
              {@fetch.url}
            </a>
          </div>
          <button type="button" phx-click="close" phx-target={@target} class="btn btn-ghost btn-sm btn-circle" aria-label={gettext("Close")}>
            <.icon name="hero-x-mark" class="h-5 w-5" />
          </button>
        </div>

        <%!-- Being looked at --%>
        <div :if={@fetch.status == "probing"} class="flex items-center gap-3 py-6" role="status">
          <span class="loading loading-spinner loading-md"></span>
          <span>{gettext("Looking at what is at %{site}…", site: @fetch.site)}</span>
        </div>

        <%!-- Nothing to fetch --%>
        <div :if={@fetch.status == "unavailable"} class="flex flex-col gap-2 py-2" role="alert">
          <p class="text-error">{Fetches.error_message(@fetch)}</p>
          <a
            :if={@fetch.error_code == "needs_login" && @logins_path}
            href={@logins_path}
            class="btn btn-sm btn-outline self-start"
          >
            <.icon name="hero-key" class="h-4 w-4" />
            {gettext("Site logins")}
          </a>
        </div>

        <%!-- Found --%>
        <div :if={@fetch.status == "ready"} class="flex min-h-0 flex-col gap-3 overflow-y-auto">
          <div class="flex gap-3">
            <img
              :if={https?(@info["thumbnail"])}
              src={@info["thumbnail"]}
              alt=""
              referrerpolicy="no-referrer"
              class="h-24 w-32 shrink-0 rounded-lg bg-base-200 object-cover"
            />
            <div class="min-w-0 text-sm">
              <p :if={@info["title"]} class="font-semibold">{@info["title"]}</p>
              <p :if={@info["author"]} class="text-base-content/70">{gettext("by %{author}", author: @info["author"])}</p>
              <p class="text-base-content/60">
                <span>{@fetch.site}</span>
                <span :if={posted(@info["posted_at"])}> · {posted(@info["posted_at"])}</span>
                <span :if={@info["duration"]}> · {duration(@info["duration"])}</span>
              </p>
              <p :if={@info["kind"] == "collection"} class="mt-1 text-base-content/80">
                {ngettext("%{count} item", "%{count} items", length(@info["entries"] || []))}
                <span :if={@info["more"]} class="text-base-content/60">
                  {gettext("(the first %{count}; fetch again later for more)", count: length(@info["entries"] || []))}
                </span>
              </p>
            </div>
          </div>

          <p :if={@info["previous"]} class="rounded-lg bg-info/10 p-2 text-xs">
            {gettext("You fetched this link into this library before (%{date}). What is already here is not added twice.", date: posted(@info["previous"]))}
          </p>

          <%!-- An album, a profile, a playlist: each entry can be left out. --%>
          <div :if={@info["kind"] == "collection"}>
            <div class="mb-1 flex items-center justify-between text-xs">
              <span>{gettext("%{picked} of %{count} chosen", picked: MapSet.size(@picked), count: length(@info["entries"] || []))}</span>
              <span class="flex gap-1">
                <button type="button" phx-click="select" phx-value-all="true" phx-target={@target} class="btn btn-ghost btn-xs">{gettext("All")}</button>
                <button type="button" phx-click="select" phx-value-all="false" phx-target={@target} class="btn btn-ghost btn-xs">{gettext("None")}</button>
              </span>
            </div>
            <div class="grid max-h-72 grid-cols-3 gap-2 overflow-y-auto sm:grid-cols-5">
              <label
                :for={entry <- @info["entries"] || []}
                class={[
                  "relative cursor-pointer overflow-hidden rounded-lg border-2 bg-base-200",
                  MapSet.member?(@picked, to_string(entry["index"])) && "border-primary",
                  !MapSet.member?(@picked, to_string(entry["index"])) && "border-transparent opacity-50"
                ]}
                title={entry["title"]}
              >
                <input
                  type="checkbox"
                  name="items[]"
                  value={entry["index"]}
                  checked={MapSet.member?(@picked, to_string(entry["index"]))}
                  class="checkbox checkbox-primary checkbox-xs absolute top-1 left-1 bg-base-100"
                />
                <img
                  :if={https?(entry["thumbnail"])}
                  src={entry["thumbnail"]}
                  alt=""
                  loading="lazy"
                  referrerpolicy="no-referrer"
                  class="aspect-square w-full object-cover"
                />
                <div :if={!https?(entry["thumbnail"])} class="flex aspect-square w-full items-center justify-center">
                  <.icon name={if entry["kind"] == "video", do: "hero-film", else: "hero-photo"} class="h-6 w-6 text-base-content/40" />
                </div>
                <span :if={entry["duration"]} class="badge badge-neutral badge-xs absolute right-1 bottom-1">{duration(entry["duration"])}</span>
              </label>
            </div>
          </div>
          <input :if={@info["kind"] != "collection"} type="hidden" name="items[]" value="1" />

          <%!-- A video's quality, when there is more than one to choose. --%>
          <fieldset :if={quality_choice?(@info)} class="text-sm">
            <legend class="mb-1 font-medium">{gettext("Quality")}</legend>
            <label class="flex items-center gap-2">
              <input type="radio" name="quality" value="default" class="radio radio-sm" checked={@form["quality"] != "best"} />
              <span>
                {gettext("Up to %{height}p", height: @info["heights"]["default"] || 1080)}
                <span :if={@info["sizes"]["default"]} class="text-base-content/60">(~{bytes(@info["sizes"]["default"])})</span>
              </span>
            </label>
            <label class="mt-1 flex items-center gap-2">
              <input type="radio" name="quality" value="best" class="radio radio-sm" checked={@form["quality"] == "best"} />
              <span>
                {gettext("Best available, %{height}p", height: @info["heights"]["best"])}
                <span :if={@info["sizes"]["best"]} class="text-base-content/60">(~{bytes(@info["sizes"]["best"])})</span>
              </span>
            </label>
          </fieldset>
          <p :if={!quality_choice?(@info) && @info["sizes"]["default"]} class="text-xs text-base-content/60">
            {gettext("About %{size}", size: bytes(@info["sizes"]["default"]))}
          </p>

          <p :if={@public?} class="rounded-lg bg-warning/15 p-2 text-xs" role="note">
            {gettext("This library is shared. Everyone who can see it will see what you fetch, with where it came from.")}
          </p>

          <%!-- The person's word that they may keep a copy. Unticked every time. --%>
          <label class="flex cursor-pointer items-start gap-2 rounded-lg border border-base-300 p-3 text-sm">
            <input type="checkbox" name="rights" value="true" class="checkbox checkbox-sm mt-0.5" checked={@form["rights"] == true} />
            <span>{Fetches.rights_text()}</span>
          </label>
        </div>

        <p :if={@notice} class="text-sm text-error" role="alert">{@notice}</p>

        <div class="modal-action mt-0">
          <button
            type="button"
            phx-click="cancel"
            phx-value-uuid={@fetch.uuid}
            phx-target={@target}
            class="btn btn-ghost"
          >
            {gettext("Forget")}
          </button>
          <button
            :if={@fetch.status == "unavailable"}
            type="button"
            phx-click="retry"
            phx-value-uuid={@fetch.uuid}
            phx-target={@target}
            class="btn"
          >
            {gettext("Try again")}
          </button>
          <button
            :if={@fetch.status == "ready"}
            type="submit"
            class="btn btn-primary"
            disabled={@form["rights"] != true or MapSet.size(@picked) == 0}
          >
            <.icon name="hero-arrow-down-tray" class="h-4 w-4" />
            {fetch_label(@info, MapSet.size(@picked))}
          </button>
        </div>
      </form>
    </dialog>
    """
  end

  defp https?(url), do: is_binary(url) and String.starts_with?(url, "https://")

  defp quality_choice?(%{"kind" => "single", "heights" => %{"default" => d, "best" => b}})
       when is_integer(d) and is_integer(b),
       do: b > d

  defp quality_choice?(_info), do: false

  defp fetch_label(%{"kind" => "collection"}, count),
    do: ngettext("Fetch %{count} item", "Fetch %{count} items", count)

  defp fetch_label(_info, _count), do: gettext("Fetch")

  defp posted(iso) when is_binary(iso) do
    case NaiveDateTime.from_iso8601(iso) do
      {:ok, at} -> Calendar.strftime(at, "%-d %b %Y")
      _ -> nil
    end
  end

  defp posted(_iso), do: nil
end
