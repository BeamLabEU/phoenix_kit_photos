defmodule PhoenixKitPhotos.Components.PhotoUploader do
  @moduledoc """
  Adds photos and videos to one library: a floating **+** button, a panel with the
  queue, and the whole page as a place to drop files or folders.

  ## Usage

      <.live_component
        module={PhoenixKitPhotos.Components.PhotoUploader}
        id="uploader"
        library_uuid={library_uuid}
        auth={scope}
      />

  `auth` is the current `PhoenixKit.Users.Auth.Scope`. The component shows nothing at
  all to someone who may not add to the library (`PhoenixKitPhotos.Uploads.can_upload?/2`:
  a user library's owner, managers and contributors; for Media, the admins and holders
  of `media`), and checks again before it stores anything.

  ## What it does

    * **Pick or drop.** The **+** button opens a panel with *Choose files*; dropping files
      or a whole folder anywhere on the page adds them (a folder's sidecars and system
      litter are left out, and said so). A drop of thousands is fed to the upload in
      batches by the `PhotoUploader` hook.
    * **Straight in.** In a private library files start uploading as soon as they are
      chosen. In a **public** library (`Libraries.public?/1`: anyone can see what is
      in it) they wait for *Upload*, with the warning in front of them.
    * **Progress, per file**, and what became of each: added, already there, in
      another of your libraries, or why not. A file is checked for duplicates by its
      bytes and its renditions are made in the background; the timeline shows it when
      they are ready (`PhoenixKitPhotos.LiveUpdates`).

  Memory: the browser sends the file in chunks that LiveView writes to disk, and the file
  is hashed and stored from disk, so a video costs what a thumbnail does.

  ## Options

    * `:on_stored` — an atom. When set, the parent LiveView gets
      `{on_stored, component_id, {:added | :duplicate | :elsewhere, file} | {:error, reason}}`
      for each finished file; it must have a clause for it. Unset, nothing is sent.

  Requires the `PhotoUploader` hook, which ships in this package's JS bundle.
  """

  use Phoenix.LiveComponent
  use Gettext, backend: PhoenixKitPhotos.Gettext

  import PhoenixKitWeb.Components.Core.Icon, only: [icon: 1]

  alias PhoenixKit.Modules.Storage.Libraries
  alias PhoenixKitPhotos.Uploads

  @upload :photos
  @max_results 50

  @impl true
  def mount(socket) do
    {:ok,
     assign(socket,
       open: false,
       done: [],
       skipped: 0,
       unreadable: 0,
       truncated: false,
       waiting: 0,
       library: nil,
       library_uuid: nil,
       can_upload: false,
       public?: false,
       upload_auto: nil
     )}
  end

  @impl true
  def update(assigns, socket) do
    library_uuid = to_string(assigns.library_uuid)
    changed? = socket.assigns.library_uuid not in [nil, library_uuid]

    socket =
      socket
      |> assign(:id, assigns.id)
      |> assign(:auth, assigns[:auth])
      |> assign(:on_stored, assigns[:on_stored])
      |> assign(:library_uuid, library_uuid)
      |> then(&if(changed?, do: forget(&1), else: &1))
      |> assign_library()
      |> configure_upload()

    {:ok, socket}
  end

  # The library changed under the panel: what was said about the last one is not
  # about this one.
  defp forget(socket),
    do: assign(socket, done: [], skipped: 0, unreadable: 0, truncated: false, waiting: 0)

  defp assign_library(socket) do
    uuid = socket.assigns.library_uuid
    library = Uploads.library(uuid)

    socket
    |> assign(:library, library)
    |> assign(:can_upload, Uploads.can_upload?(socket.assigns.auth, uuid))
    |> assign(:public?, Libraries.published?(library))
    |> assign(:anonymous?, Libraries.public?(library))
  end

  # Nothing is allowed to someone who may not add. Otherwise the upload is set up once;
  # a library that is public (or not) differs in one thing, whether files start by
  # themselves, so the upload is set up again when that changes.
  defp configure_upload(%{assigns: %{can_upload: false}} = socket), do: socket

  defp configure_upload(socket) do
    auto? = not socket.assigns.public?

    case socket.assigns.upload_auto do
      ^auto? ->
        socket

      nil ->
        allow(socket, auto?)

      _other ->
        socket
        |> cancel_all()
        |> disallow_upload(@upload)
        |> allow(auto?)
    end
  end

  defp allow(socket, auto?) do
    socket
    |> allow_upload(@upload,
      accept: Uploads.accept(),
      max_entries: Uploads.max_entries(),
      max_file_size: Uploads.max_file_size(),
      auto_upload: auto?,
      progress: &__MODULE__.handle_progress/3
    )
    |> assign(:upload_auto, auto?)
  end

  defp cancel_all(socket) do
    Enum.reduce(socket.assigns.uploads[@upload].entries, socket, fn entry, socket ->
      cancel_upload(socket, @upload, entry.ref)
    end)
  end

  @doc false
  # One file finished arriving: store it and say what became of it.
  def handle_progress(@upload, entry, socket) do
    if entry.done? do
      outcome =
        consume_uploaded_entry(socket, entry, fn %{path: path} ->
          {:ok, Uploads.store(path, entry, socket.assigns.auth, socket.assigns.library_uuid)}
        end)

      {:noreply, socket |> record(entry, outcome) |> notify(outcome)}
    else
      {:noreply, socket}
    end
  end

  defp reject_invalid(socket) do
    config = socket.assigns.uploads[@upload]

    Enum.reduce(config.entries, socket, fn entry, socket ->
      case upload_errors(config, entry) do
        [] ->
          socket

        [error | _] ->
          socket
          |> cancel_upload(@upload, entry.ref)
          |> record(entry, {:error, {:rejected, error}})
      end
    end)
  end

  defp record(socket, entry, outcome) do
    item = %{ref: entry.ref, name: entry.client_name, outcome: outcome}
    assign(socket, :done, Enum.take([item | socket.assigns.done], @max_results))
  end

  defp notify(%{assigns: %{on_stored: event, id: id}} = socket, outcome)
       when is_atom(event) and not is_nil(event) do
    send(self(), {event, id, outcome})
    socket
  end

  defp notify(socket, _outcome), do: socket

  @impl true
  def handle_event("open", _params, socket), do: {:noreply, assign(socket, :open, true)}
  def handle_event("close", _params, socket), do: {:noreply, assign(socket, :open, false)}

  # The form's change events: files were chosen or dropped. An entry LiveView turned
  # away (not a photo, too large) is reported and cancelled, not left in the list: it
  # would hold one of the batch's places for good, the hook would wait for it to finish
  # before sending the next batch, and nothing ever would.
  def handle_event("validate", _params, socket) do
    {:noreply, reject_invalid(socket)}
  end

  # A private library uploads as files are chosen; a public one waits for this.
  def handle_event("start", _params, socket), do: {:noreply, socket}

  def handle_event("cancel", %{"ref" => ref}, socket) do
    {:noreply, cancel_upload(socket, @upload, ref)}
  end

  def handle_event("dismiss", _params, socket) do
    {:noreply, assign(socket, done: [], skipped: 0, unreadable: 0, truncated: false)}
  end

  # From the hook: files were dropped (and how many were left out of a folder).
  def handle_event("dropped", params, socket) do
    {:noreply,
     assign(socket,
       open: true,
       skipped: socket.assigns.skipped + count(params["skipped"]),
       unreadable: socket.assigns.unreadable + count(params["unreadable"]),
       truncated: params["truncated"] == true
     )}
  end

  # The hook asks before it sends the next batch of a big drop: nothing may be left
  # uploading, nor waiting for a click (a public library), nor not yet registered.
  def handle_event("ready", _params, socket) do
    {:reply, %{idle: socket.assigns.uploads[@upload].entries == []}, socket}
  end

  def handle_event("waiting", params, socket) do
    {:noreply, assign(socket, :waiting, count(params["count"]))}
  end

  defp count(n) when is_integer(n) and n >= 0, do: n
  defp count(_other), do: 0

  # ---------------------------------------------------------------------------

  @impl true
  # Nothing for someone who may not add. A stateful component still has to render one
  # tag at its root.
  def render(%{can_upload: false} = assigns), do: ~H"<div id={@id} hidden></div>"

  def render(assigns) do
    entries = assigns.uploads[@upload].entries

    assigns =
      assigns
      |> assign(:entries, entries)
      |> assign(:busy, length(entries) + assigns.waiting)
      |> assign(:added, count_outcome(assigns.done, :added))
      |> assign(:duplicates, count_outcome(assigns.done, :duplicate))
      |> assign(:elsewhere, count_outcome(assigns.done, :elsewhere))
      |> assign(:failed, count_outcome(assigns.done, :error))

    ~H"""
    <div
      id={@id}
      phx-hook="PhotoUploader"
      phx-target={@myself}
      data-upload-name={@uploads.photos.name}
      data-accept={Jason.encode!(PhoenixKitPhotos.Uploads.accept())}
      data-batch={PhoenixKitPhotos.Uploads.max_entries()}
    >
      <%!-- Shown while files are dragged over the page; it never takes a click. --%>
      <div
        data-drop-overlay
        aria-hidden="true"
        class="pointer-events-none fixed inset-0 z-[70] flex items-center justify-center bg-primary/15 opacity-0 transition-opacity data-[active]:opacity-100"
      >
        <div class="rounded-box border-2 border-dashed border-primary bg-base-100 px-8 py-6 text-center shadow-xl">
          <.icon name="hero-arrow-up-tray" class="mx-auto mb-2 h-8 w-8 text-primary" />
          <p class="text-lg font-semibold">{gettext("Drop to add to %{name}", name: library_name(@library))}</p>
          <p class="text-sm text-base-content/60">{gettext("Photos, videos or whole folders")}</p>
        </div>
      </div>

      <form id={"#{@id}-form"} phx-change="validate" phx-submit="start" phx-target={@myself}>
        <%!-- Always in the page: the hook hands dropped files to this input. --%>
        <.live_file_input upload={@uploads.photos} class="sr-only" />

        <button
          :if={!@open}
          type="button"
          phx-click="open"
          phx-target={@myself}
          class="btn btn-primary btn-circle btn-lg fixed bottom-6 right-6 z-40 shadow-lg"
          aria-label={gettext("Add photos")}
          title={gettext("Add photos")}
        >
          <span :if={@busy > 0} class="loading loading-spinner"></span>
          <.icon :if={@busy == 0} name="hero-plus" class="h-7 w-7" />
          <span :if={@busy > 0} class="badge badge-neutral badge-sm absolute -top-1 -right-1">{@busy}</span>
        </button>

        <section
          :if={@open}
          id={"#{@id}-panel"}
          aria-label={gettext("Add photos")}
          class="card fixed inset-x-3 bottom-3 z-50 max-h-[80vh] border border-base-300 bg-base-100 shadow-2xl sm:inset-x-auto sm:right-6 sm:bottom-6 sm:w-96"
        >
          <div class="card-body gap-3 overflow-y-auto p-4">
            <div class="flex items-start justify-between gap-2">
              <div class="min-w-0">
                <h2 class="card-title text-base">{gettext("Add photos")}</h2>
                <p class="flex items-center gap-1 truncate text-sm text-base-content/70">
                  <.icon :if={@public?} name="hero-globe-alt" class="h-4 w-4 shrink-0" />
                  <.icon :if={!@public?} name="hero-lock-closed" class="h-4 w-4 shrink-0" />
                  <span class="truncate">{library_name(@library)}</span>
                </p>
              </div>
              <button type="button" phx-click="close" phx-target={@myself} class="btn btn-ghost btn-sm btn-circle" aria-label={gettext("Close")}>
                <.icon name="hero-x-mark" class="h-5 w-5" />
              </button>
            </div>

            <p :if={@public?} class="rounded-lg bg-warning/15 p-2 text-xs text-warning-content" role="note">
              <%= if @anonymous? do %>
                {gettext("This library is public. Everything you add to it can be seen by anyone.")}
              <% else %>
                {gettext("This library is shared with signed-in users. Every active account on this site can see what you add.")}
              <% end %>
            </p>

            <label
              for={@uploads.photos.ref}
              class="flex cursor-pointer flex-col items-center gap-1 rounded-lg border-2 border-dashed border-base-300 p-4 text-center hover:border-primary"
            >
              <.icon name="hero-arrow-up-tray" class="h-6 w-6 text-primary" />
              <span class="font-medium">{gettext("Choose files")}</span>
              <span class="text-xs text-base-content/60">{gettext("or drop photos, videos or folders anywhere on the page")}</span>
            </label>

            <p :for={error <- upload_errors(@uploads.photos)} class="text-sm text-error" role="alert">
              {Uploads.entry_error(error)}
            </p>

            <ul :if={@entries != []} class="flex flex-col gap-2" aria-live="polite">
              <li :for={entry <- @entries} class="flex flex-col gap-1">
                <div class="flex items-center gap-2 text-sm">
                  <span class="min-w-0 flex-1 truncate" title={entry.client_name}>{entry.client_name}</span>
                  <span :if={@upload_auto || entry.progress > 0} class="shrink-0 text-xs text-base-content/60">{entry.progress}%</span>
                  <span :if={!@upload_auto && entry.progress == 0 && upload_errors(@uploads.photos, entry) == []} class="shrink-0 text-xs text-base-content/60">{gettext("waiting")}</span>
                  <button type="button" phx-click="cancel" phx-value-ref={entry.ref} phx-target={@myself} class="btn btn-ghost btn-xs btn-circle" aria-label={gettext("Cancel")}>
                    <.icon name="hero-x-mark" class="h-4 w-4" />
                  </button>
                </div>
                <progress :if={upload_errors(@uploads.photos, entry) == []} class="progress progress-primary h-1.5 w-full" value={entry.progress} max="100"></progress>
                <p :for={error <- upload_errors(@uploads.photos, entry)} class="text-xs text-error" role="alert">
                  {Uploads.entry_error(error)}
                </p>
              </li>
            </ul>

            <p :if={@waiting > 0} class="text-xs text-base-content/60">
              {ngettext("%{count} more file is waiting", "%{count} more files are waiting", @waiting)}
            </p>

            <button
              :if={!@upload_auto && @entries != []}
              type="submit"
              class="btn btn-primary btn-sm"
            >
              {ngettext("Upload %{count} file", "Upload %{count} files", length(@entries))}
            </button>

            <div :if={@done != [] || @skipped > 0 || @unreadable > 0} class="flex flex-col gap-1 border-t border-base-300 pt-2 text-sm" aria-live="polite">
              <p class="flex flex-wrap items-center gap-x-3 gap-y-1">
                <span :if={@added > 0} class="flex items-center gap-1 text-success"><.icon name="hero-check-circle" class="h-4 w-4" />{gettext("%{count} added", count: @added)}</span>
                <span :if={@duplicates > 0} class="flex items-center gap-1 text-base-content/70"><.icon name="hero-document-duplicate" class="h-4 w-4" />{gettext("%{count} already there", count: @duplicates)}</span>
                <span :if={@elsewhere > 0} class="flex items-center gap-1 text-warning"><.icon name="hero-arrow-uturn-right" class="h-4 w-4" />{gettext("%{count} in another library", count: @elsewhere)}</span>
                <span :if={@failed > 0} class="flex items-center gap-1 text-error"><.icon name="hero-exclamation-triangle" class="h-4 w-4" />{gettext("%{count} failed", count: @failed)}</span>
              </p>
              <p :if={@skipped > 0} class="text-xs text-base-content/60">
                {ngettext("%{count} file in the folder was left out (not a photo or video)", "%{count} files in the folder were left out (not photos or videos)", @skipped)}
              </p>
              <p :if={@unreadable > 0} class="text-xs text-warning" role="alert">
                {ngettext(
                  "%{count} folder could not be read. Use Choose files to pick its photos instead.",
                  "%{count} folders could not be read. Use Choose files to pick their photos instead.",
                  @unreadable
                )}
              </p>
              <p :if={@truncated} class="text-xs text-warning">{gettext("That folder is very large; only the first part was taken. Drop the rest again.")}</p>

              <ul :if={@failed > 0 || @elsewhere > 0} class="flex flex-col gap-0.5 text-xs">
                <li :for={item <- failures(@done)} class="flex gap-2">
                  <span class="min-w-0 flex-1 truncate" title={item.name}>{item.name}</span>
                  <span class="shrink-0 text-base-content/60">{outcome_message(item.outcome)}</span>
                </li>
              </ul>

              <button :if={@entries == []} type="button" phx-click="dismiss" phx-target={@myself} class="btn btn-ghost btn-xs self-end">
                {gettext("Clear")}
              </button>
            </div>
          </div>
        </section>
      </form>
    </div>
    """
  end

  defp library_name(%{name: name}), do: name
  defp library_name(_library), do: ""

  defp count_outcome(done, kind), do: Enum.count(done, &match?(%{outcome: {^kind, _}}, &1))

  defp failures(done),
    do: Enum.filter(done, &match?(%{outcome: {kind, _}} when kind in [:error, :elsewhere], &1))

  defp outcome_message({:elsewhere, _file}), do: gettext("already in another of your libraries")
  defp outcome_message({:error, reason}), do: Uploads.error_message(reason)
end
