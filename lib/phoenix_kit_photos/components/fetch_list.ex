defmodule PhoenixKitPhotos.Components.FetchList do
  @moduledoc """
  A person's fetches from links, all libraries together, and their **site logins**: the
  page a host gives them in their settings.

      <.live_component
        module={PhoenixKitPhotos.Components.FetchList}
        id="fetches"
        auth={scope}
        library_link={&MyAppWeb.library_link/1}
      />

  `library_link` (optional) is called with a library uuid and gives `{name, href}` or
  nil, for the line under each card and for *Review and fetch*, which opens the dialog
  in its library (`href` with `?fetch=<uuid>`, which the library page hands its
  `LinkFetcher` as `open`). The cards move with the fetches when the page mounts
  `PhoenixKitPhotos.LiveUpdates`.

  ## Site logins

  Sites like Instagram and X show their posts only to someone logged in. A person can
  give Fotki **their own** login for such a site, as their browser's cookies for it:
  exported with a browser extension as `cookies.txt` and pasted here. Only that site's
  cookies are kept, encrypted (`PhoenixKitPhotos.Fetches.SiteLogins`), and they are used
  only for this person's fetches. Once saved they are never shown again: the list says
  the site, how many cookies, when they were added and when they last worked or failed.
  """

  use Phoenix.LiveComponent
  use Gettext, backend: PhoenixKitPhotos.Gettext

  import PhoenixKitWeb.Components.Core.Icon, only: [icon: 1]
  import PhoenixKitPhotos.Components.FetchCards, only: [card: 1]

  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKitPhotos.{Fetches, LiveUpdates}
  alias PhoenixKitPhotos.Fetches.{Fetch, SiteLogins}

  @impl true
  def mount(socket) do
    {:ok,
     assign(socket,
       fetches: [],
       logins: [],
       libraries: %{},
       login_error: nil,
       login_saved: nil,
       notice: nil
     )}
  end

  @impl true
  def update(%{fetch_event: {:fetch, %Fetch{} = fetch}}, socket) do
    others = Enum.reject(socket.assigns.fetches, &(&1.uuid == fetch.uuid))
    fetches = if is_nil(fetch.dismissed_at), do: [fetch | others], else: others

    {:ok,
     socket
     |> assign(:fetches, Enum.sort_by(fetches, & &1.inserted_at, {:desc, NaiveDateTime}))
     |> label_libraries()}
  end

  def update(%{fetch_event: {:removed, uuid}}, socket) do
    {:ok,
     assign(
       socket,
       :fetches,
       Enum.reject(socket.assigns.fetches, &(to_string(&1.uuid) == to_string(uuid)))
     )}
  end

  def update(assigns, socket) do
    auth = assigns.auth

    if connected?(socket),
      do: LiveUpdates.watch_fetches(__MODULE__, assigns.id, Scope.user_uuid(auth))

    {:ok,
     socket
     |> assign(:id, assigns.id)
     |> assign(:auth, auth)
     |> assign(:library_link, assigns[:library_link])
     |> assign(:available?, Fetches.available?())
     |> assign(:fetches, Fetches.list(auth))
     |> assign(:logins, SiteLogins.list(auth))
     |> label_libraries()}
  end

  defp label_libraries(socket) do
    link = socket.assigns.library_link

    libraries =
      if is_function(link, 1) do
        socket.assigns.fetches
        |> Enum.map(&to_string(&1.library_uuid))
        |> Enum.uniq()
        |> Map.new(fn uuid -> {uuid, Map.get(socket.assigns.libraries, uuid) || link.(uuid)} end)
      else
        %{}
      end

    assign(socket, :libraries, libraries)
  end

  # ── Events ─────────────────────────────────────────────────────────────

  @impl true
  def handle_event("open", %{"uuid" => uuid}, socket) do
    with %Fetch{} = fetch <- Enum.find(socket.assigns.fetches, &(to_string(&1.uuid) == uuid)),
         {_name, href} when is_binary(href) <-
           Map.get(socket.assigns.libraries, to_string(fetch.library_uuid)) do
      {:noreply, push_navigate(socket, to: href <> "?fetch=" <> uuid)}
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event("cancel", %{"uuid" => uuid}, socket) do
    case Fetches.cancel(socket.assigns.auth, uuid) do
      {:ok, :removed} ->
        {:noreply,
         assign(
           socket,
           :fetches,
           Enum.reject(socket.assigns.fetches, &(to_string(&1.uuid) == uuid))
         )}

      {:ok, fetch} ->
        update_fetch(socket, fetch)

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("retry", %{"uuid" => uuid}, socket) do
    case Fetches.retry(socket.assigns.auth, uuid) do
      {:ok, fetch} ->
        update_fetch(socket, fetch)

      {:error, :nothing_missing} ->
        {:noreply, assign(socket, :notice, gettext("Everything from this link is already here."))}

      {:error, _} ->
        {:noreply,
         assign(socket, :notice, gettext("This fetch cannot be tried again right now."))}
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

  def handle_event("save_login", %{"site" => site, "cookies" => cookies}, socket) do
    case SiteLogins.put(socket.assigns.auth, site, cookies) do
      {:ok, login} ->
        {:noreply,
         assign(socket,
           logins: SiteLogins.list(socket.assigns.auth),
           login_error: nil,
           login_saved:
             gettext("Saved %{count} cookies for %{site}.",
               count: login.cookie_count,
               site: login.site
             )
         )}

      {:error, reason} ->
        {:noreply, assign(socket, login_error: login_error(reason), login_saved: nil)}
    end
  end

  def handle_event("delete_login", %{"site" => site}, socket) do
    :ok = SiteLogins.delete(socket.assigns.auth, site)
    {:noreply, assign(socket, logins: SiteLogins.list(socket.assigns.auth), login_saved: nil)}
  end

  def handle_event("hide_notice", _params, socket), do: {:noreply, assign(socket, :notice, nil)}

  defp update_fetch(socket, fetch) do
    {:ok, socket} = update(%{fetch_event: {:fetch, fetch}}, socket)
    {:noreply, socket}
  end

  defp login_error(:invalid_site),
    do: gettext("Write the site as its address, like instagram.com.")

  defp login_error(:too_big), do: gettext("That is too much text for one site's cookies.")

  defp login_error(:not_cookies_txt),
    do:
      gettext(
        "This is not a cookies.txt export. Export the cookies in the Netscape (cookies.txt) format and paste all of it."
      )

  defp login_error(:empty),
    do:
      gettext(
        "None of these cookies is for that site. Export them while you are on the site, logged in."
      )

  defp login_error(_), do: gettext("The login could not be saved.")

  # ── Rendering ──────────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    ~H"""
    <div id={@id} class="flex flex-col gap-8">
      <section aria-labelledby={"#{@id}-list-title"}>
        <h2 id={"#{@id}-list-title"} class="mb-1 text-lg font-semibold">{gettext("Fetched from links")}</h2>
        <p class="mb-3 text-sm text-base-content/70">
          {gettext("Paste a link to a photo, an album or a video into one of your libraries, and it is fetched on the server: you can close the page meanwhile.")}
        </p>
        <p :if={!@available?} class="alert alert-info mb-3 py-2 text-sm">
          {gettext("Fetching from links is not available on this site right now.")}
        </p>
        <div :if={@notice} role="alert" class="alert alert-warning mb-3 py-2 text-sm">
          <span>{@notice}</span>
          <button type="button" phx-click="hide_notice" phx-target={@myself} class="btn btn-ghost btn-xs" aria-label={gettext("Close")}>
            <.icon name="hero-x-mark" class="h-4 w-4" />
          </button>
        </div>
        <p :if={@fetches == []} class="text-sm text-base-content/60">{gettext("Nothing fetched yet.")}</p>
        <div class="grid gap-2 md:grid-cols-2">
          <.card
            :for={fetch <- @fetches}
            fetch={fetch}
            target={@myself}
            waiting={if fetch.status == "queued", do: Fetches.waiting_before(fetch), else: 0}
            library_name={library_name(@libraries, fetch)}
            library_href={library_href(@libraries, fetch)}
          />
        </div>
      </section>

      <section aria-labelledby={"#{@id}-logins-title"}>
        <h2 id={"#{@id}-logins-title"} class="mb-1 text-lg font-semibold">{gettext("Site logins")}</h2>
        <p class="mb-3 text-sm text-base-content/70">
          {gettext("Some sites, like Instagram and X, show posts only to someone logged in. To fetch from them, give Fotki your own login for that site, as your browser's cookies.")}
        </p>

        <ul :if={@logins != []} class="mb-4 divide-y divide-base-300 rounded-box border border-base-300">
          <li :for={login <- @logins} class="flex items-center gap-3 p-3 text-sm">
            <.icon name="hero-key" class="h-5 w-5 shrink-0 text-base-content/50" />
            <div class="min-w-0 flex-1">
              <p class="font-medium">{login.site}</p>
              <p class="text-xs text-base-content/60">
                {ngettext("%{count} cookie", "%{count} cookies", login.cookie_count)} · {gettext("added %{date}", date: day(login.updated_at))}
                <span :if={login.last_worked_at} class="text-success"> · {gettext("worked %{date}", date: day(login.last_worked_at))}</span>
                <span :if={login.last_failed_at} class="text-warning"> · {gettext("refused %{date}: export them again", date: day(login.last_failed_at))}</span>
              </p>
            </div>
            <button
              type="button"
              phx-click="delete_login"
              phx-value-site={login.site}
              phx-target={@myself}
              class="btn btn-ghost btn-xs"
              data-confirm={gettext("Forget your %{site} login?", site: login.site)}
            >
              {gettext("Forget")}
            </button>
          </li>
        </ul>

        <form id={"#{@id}-login-form"} phx-submit="save_login" phx-target={@myself} class="flex flex-col gap-3 rounded-box border border-base-300 p-4">
          <ol class="list-decimal space-y-1 pl-5 text-sm">
            <li>{gettext("Install a browser extension that exports cookies as cookies.txt, such as \"Get cookies.txt LOCALLY\" (Chrome, Edge) or \"cookies.txt\" (Firefox).")}</li>
            <li>{gettext("Open the site and log in, then export its cookies with the extension.")}</li>
            <li>{gettext("Write the site below and paste everything the export holds. Only that site's cookies are kept, encrypted.")}</li>
          </ol>
          <label class="flex flex-col gap-1 text-sm">
            <span>{gettext("Site")}</span>
            <input name="site" required placeholder="instagram.com" autocomplete="off" class="input input-sm w-full max-w-xs" />
          </label>
          <label class="flex flex-col gap-1 text-sm">
            <span>{gettext("cookies.txt")}</span>
            <textarea name="cookies" required rows="5" spellcheck="false" autocomplete="off" class="textarea textarea-sm w-full font-mono text-xs" placeholder="# Netscape HTTP Cookie File"></textarea>
          </label>
          <p class="text-xs text-base-content/60">
            {gettext("The site may limit or block an account used this way. Your login is used only for what you fetch, and you can forget it here at any time.")}
          </p>
          <p :if={@login_error} class="text-sm text-error" role="alert">{@login_error}</p>
          <p :if={@login_saved} class="text-sm text-success" role="status">{@login_saved}</p>
          <button type="submit" class="btn btn-primary btn-sm self-start">{gettext("Save login")}</button>
        </form>
      </section>
    </div>
    """
  end

  defp library_name(libraries, fetch) do
    case Map.get(libraries, to_string(fetch.library_uuid)) do
      {name, _href} -> name
      _ -> nil
    end
  end

  defp library_href(libraries, fetch) do
    case Map.get(libraries, to_string(fetch.library_uuid)) do
      {_name, href} -> href
      _ -> nil
    end
  end

  defp day(%NaiveDateTime{} = at), do: Calendar.strftime(at, "%-d %b %Y")
  defp day(_), do: ""
end
