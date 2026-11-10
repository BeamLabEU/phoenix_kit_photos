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
      litter are left out, and said so). A drop of thousands is fed to the upload by the
      `PhotoUploader` hook in a sliding window: at most as many files in flight as the
      panel's "Uploads at once" control says (`Uploads.max_concurrent_uploads/0` unless
      the person changed it), never more than one batch (`Uploads.max_entries/0`).
    * **Straight in.** In a private library files start uploading as soon as they are
      chosen. In a **public** library (`Libraries.public?/1`: anyone can see what is
      in it) they wait for *Upload*, with the warning in front of them.
    * **Progress, per file**, and what became of each: added, already there, in
      another of your libraries, or why not. A file is checked for duplicates by its
      bytes and its renditions are made in the background; the timeline shows it when
      they are ready (`PhoenixKitPhotos.LiveUpdates`).

  Memory: the browser sends the file in chunks that LiveView writes to disk, and the file
  is hashed and stored from disk, so a video costs what a thumbnail does.

  ## Saving in the background

  A finished file is stored off the page when the page can hear back: it mounts
  `PhoenixKitPhotos.LiveUpdates` and the host runs the `photo_uploads` Oban queue
  (`PhoenixKitPhotos.StoreUploadJob.available?/0`). The file is checked (who may add,
  what it is: `Uploads.precheck/4`), moved out of LiveView's temp file
  (`PhoenixKitPhotos.UploadStaging`) and listed as *Saving…* until the job says what
  became of it; storage being slow or down is retried there, and the page never waits
  for it. A page that waits too long for the server is disconnected and reloaded by
  LiveView's client, which ends every upload in flight, so this matters most for large
  files and slow storage. Otherwise (no hook, no queue) the file is stored inline, as
  before. A file that is saving stays saving after a reload; only the panel forgets it.

  ## Options

    * `:on_stored` — an atom. When set, the parent LiveView gets
      `{on_stored, component_id, {:added | :duplicate | :elsewhere, file} | {:error, reason}}`
      for each finished file; it must have a clause for it. Unset, nothing is sent.

  Requires the `PhotoUploader` hook, which ships in this package's JS bundle.
  """

  use Phoenix.LiveComponent
  use Gettext, backend: PhoenixKitPhotos.Gettext

  import PhoenixKitWeb.Components.Core.Icon, only: [icon: 1]

  require Logger

  alias PhoenixKit.Modules.Storage.Libraries
  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKitPhotos.{LiveUpdates, StagingSweepJob, StoreUploadJob, Uploads, UploadStaging}

  @upload :photos
  @max_results 50
  # How many waiting file names the hook may send for the panel to list; the rest is
  # only counted ("N more files are waiting"), so a drop of thousands stays cheap.
  @max_queued_names 50
  # How many files may be saving before the hook is told the window is fuller than its
  # entries alone say: past this, every file still saving holds a place, so a store that
  # falls behind slows the transfer down instead of filling the server's disk.
  @saving_slack 8

  @impl true
  def mount(socket) do
    {:ok,
     assign(socket,
       open: false,
       done: [],
       saving: [],
       skipped: 0,
       unreadable: 0,
       truncated: false,
       waiting: 0,
       queued: [],
       started: false,
       library: nil,
       library_uuid: nil,
       can_upload: false,
       public?: false,
       upload_auto: nil
     )}
  end

  @impl true
  # What `PhoenixKitPhotos.StoreUploadJob` said about a file this panel handed it,
  # relayed by `PhoenixKitPhotos.LiveUpdates`.
  def update(%{upload_event: {ref, event}}, socket), do: {:ok, upload_event(socket, ref, event)}

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
    do:
      assign(socket,
        done: [],
        saving: [],
        skipped: 0,
        unreadable: 0,
        truncated: false,
        waiting: 0,
        queued: [],
        started: false
      )

  defp assign_library(socket) do
    uuid = socket.assigns.library_uuid
    library = Uploads.library(uuid)

    socket
    |> assign(:library, library)
    |> assign(:can_upload, Uploads.can_upload?(socket.assigns.auth, uuid))
    |> assign(:public?, Libraries.published?(library))
    |> assign(:anonymous?, Libraries.public?(library))
  end

  # Nothing is allowed to someone who may not add. The upload always starts entries as
  # they are handed to it (`auto_upload: true`), so the hook's concurrency window works
  # the same in every library: in a public one the hook holds files in its queue until
  # Upload is pressed (the consent the warning is about) and then feeds them through
  # the window. `upload_auto` records only whether that gate exists, for the render
  # and the hook's `data-auto`; the upload is set up again if it changes.
  defp configure_upload(%{assigns: %{can_upload: false}} = socket) do
    # Cancellation finishes asynchronously; disallow_upload/2 would raise while
    # the cancelled entries still exist. Keep the config for a later regrant.
    socket = if socket.assigns.upload_auto == nil, do: socket, else: cancel_all(socket)
    assign(socket, open: false, waiting: 0, queued: [], started: false)
  end

  defp configure_upload(socket) do
    gated? = socket.assigns.public?
    auto? = not gated?

    case socket.assigns.upload_auto do
      ^auto? ->
        socket

      nil ->
        allow(socket, gated?)

      _other ->
        socket
        |> cancel_all()
        |> disallow_upload(@upload)
        |> allow(gated?)
    end
  end

  defp allow(socket, gated?) do
    socket
    |> allow_upload(@upload,
      accept: Uploads.accept(),
      max_entries: Uploads.max_entries(),
      max_file_size: Uploads.max_file_size(),
      auto_upload: true,
      progress: &__MODULE__.handle_progress/3
    )
    |> assign(:upload_auto, not gated?)
  end

  defp cancel_all(socket) do
    Enum.reduce(socket.assigns.uploads[@upload].entries, socket, fn entry, socket ->
      cancel_upload(socket, @upload, entry.ref)
    end)
  end

  @doc false
  # One file finished arriving: hand it to the background store (or store it here, see
  # the moduledoc) and say what became of it. A cancelled entry (its x, or Cancel all) is
  # never stored. The callback must be quick in the background case: it runs while the
  # page waits, and LiveView's temp file is only safe until it returns.
  def handle_progress(@upload, entry, socket) do
    if entry.done? and not entry.cancelled? do
      case consume(socket, entry, background?()) do
        {:saving, item} ->
          {:noreply, assign(socket, :saving, socket.assigns.saving ++ [item])}

        outcome ->
          {:noreply, socket |> record(entry.ref, entry.client_name, outcome) |> notify(outcome)}
      end
    else
      {:noreply, socket}
    end
  end

  defp consume(socket, entry, true = _background?),
    do: consume_uploaded_entry(socket, entry, &{:ok, hand_over(&1.path, entry, socket)})

  defp consume(socket, entry, false = _background?),
    do: consume_uploaded_entry(socket, entry, &{:ok, store_here(&1.path, entry, socket)})

  defp background?, do: is_binary(LiveUpdates.upload_topic()) and StoreUploadJob.available?()

  defp store_here(path, entry, socket),
    do: Uploads.store(path, entry, socket.assigns.auth, socket.assigns.library_uuid)

  # The cheap checks first, so a refusal is said at once; then the file leaves LiveView's
  # temp file and a job stores it. If either step fails, the file is stored here after
  # all, from wherever it is now, rather than lost.
  defp hand_over(path, entry, socket) do
    %{auth: scope, library_uuid: library_uuid, id: id} = socket.assigns

    with :ok <- Uploads.precheck(path, entry, scope, library_uuid),
         {:staged, {:ok, staged}} <- {:staged, UploadStaging.stage(path)} do
      upload = %{
        name: entry.client_name,
        type: entry.client_type,
        user_uuid: Scope.user_uuid(scope),
        library_uuid: library_uuid,
        topic: LiveUpdates.upload_topic(),
        component: id,
        ref: entry.ref
      }

      case Oban.insert(StoreUploadJob.new_store(staged, upload)) do
        {:ok, _job} ->
          StagingSweepJob.schedule()
          {:saving, %{ref: entry.ref, name: entry.client_name, retrying: nil}}

        {:error, reason} ->
          Logger.warning("[PhotoUploader] could not queue a store: #{inspect(reason)}")
          outcome = store_here(staged, entry, socket)
          UploadStaging.discard(staged)
          outcome
      end
    else
      {:staged, {:error, reason}} ->
        Logger.warning("[PhotoUploader] could not stage an upload: #{inspect(reason)}")
        store_here(path, entry, socket)

      {:error, _reason} = refused ->
        refused
    end
  end

  defp upload_event(socket, ref, {:stored, outcome}) do
    case Enum.split_with(socket.assigns.saving, &(&1.ref == ref)) do
      {[item | _], rest} ->
        socket
        |> assign(:saving, rest)
        |> record(item.ref, item.name, outcome)
        |> notify(outcome)

      {[], _rest} ->
        socket
    end
  end

  defp upload_event(socket, ref, {:retrying, attempt}) do
    saving =
      Enum.map(socket.assigns.saving, fn
        %{ref: ^ref} = item -> %{item | retrying: attempt}
        item -> item
      end)

    assign(socket, :saving, saving)
  end

  defp upload_event(socket, _ref, _event), do: socket

  defp reject_invalid(socket) do
    config = socket.assigns.uploads[@upload]

    Enum.reduce(config.entries, socket, fn entry, socket ->
      case upload_errors(config, entry) do
        [] ->
          socket

        [error | _] ->
          socket
          |> cancel_upload(@upload, entry.ref)
          |> record(entry.ref, entry.client_name, {:error, {:rejected, error}})
      end
    end)
  end

  defp record(socket, ref, name, outcome) do
    item = %{ref: ref, name: name, outcome: outcome}
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

  # Upload was pressed: in a public library the hook now starts feeding the queue
  # through the window. (In a private one the button is not shown.) The flag only
  # hides the button while a gated upload runs; new files set it back.
  def handle_event("start", _params, socket), do: {:noreply, assign(socket, :started, true)}

  def handle_event("cancel", %{"ref" => ref}, socket) do
    {:noreply, cancel_upload(socket, @upload, ref)}
  end

  # Cancel all: every entry in flight or waiting. The hook empties its own queue of
  # not-yet-sent files when it sees this button clicked (`data-cancel-all`).
  def handle_event("cancel_all", _params, socket) do
    {:noreply, socket |> cancel_all() |> assign(waiting: 0, queued: [])}
  end

  def handle_event("dismiss", _params, socket) do
    {:noreply,
     assign(socket, done: [], skipped: 0, unreadable: 0, truncated: false, waiting: 0, queued: [])}
  end

  # From the hook: files were picked or dropped (and how many were left out of a
  # folder). In a public library these wait for Upload again, so the flag resets.
  def handle_event("dropped", params, socket) do
    {:noreply,
     assign(socket,
       open: true,
       started: false,
       skipped: socket.assigns.skipped + count(params["skipped"]),
       unreadable: socket.assigns.unreadable + count(params["unreadable"]),
       truncated: params["truncated"] == true
     )}
  end

  # The hook asks before it sends more of a big drop, and how much room it has: how
  # many entries are still in flight (uploading, waiting for a click in a public
  # library, or not yet registered), plus the files saving beyond `@saving_slack`. It
  # keeps at most its concurrency control's number in flight, so `idle` is the window
  # closed all the way.
  def handle_event("ready", _params, socket) do
    entries = socket.assigns.uploads[@upload].entries
    backlog = max(length(socket.assigns.saving) - @saving_slack, 0)

    {:reply, %{idle: entries == [] and backlog == 0, in_flight: length(entries) + backlog},
     socket}
  end

  # From the hook after it hands a batch to LiveView: how many files are still in its
  # queue, and the first few names, so the panel can list the whole selection — not
  # just the ones in flight (the concurrency window), which are the entries above.
  def handle_event("waiting", params, socket) do
    names =
      params["names"]
      |> List.wrap()
      |> Enum.take(@max_queued_names)
      |> Enum.map(&String.slice(to_string(&1), 0, 255))

    {:noreply, assign(socket, waiting: count(params["count"]), queued: names)}
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
      |> assign(:busy, length(entries) + length(assigns.saving) + assigns.waiting)
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
      data-concurrency={PhoenixKitPhotos.Uploads.max_concurrent_uploads()}
      data-concurrency-max={PhoenixKitPhotos.Uploads.max_concurrency_choice()}
      data-auto={to_string(@upload_auto)}
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

            <%!-- Purely the hook's: how many files it keeps in flight. The choice is kept
                 in the browser (localStorage), so no event goes to the server. --%>
            <label class="flex items-center justify-between gap-2 text-xs text-base-content/60">
              <span>{gettext("Uploads at once")}</span>
              <select
                data-concurrency-select
                class="select select-xs"
                aria-label={gettext("Uploads at once")}
              >
                <option
                  :for={n <- 1..Uploads.max_concurrency_choice()}
                  value={n}
                  selected={n == Uploads.max_concurrent_uploads()}
                >
                  {n}
                </option>
              </select>
            </label>

            <p :for={error <- upload_errors(@uploads.photos)} class="text-sm text-error" role="alert">
              {Uploads.entry_error(error)}
            </p>

            <ul :if={@entries != []} class="flex flex-col gap-2" aria-live="polite">
              <li :for={entry <- @entries} class="flex flex-col gap-1">
                <div class="flex items-center gap-2 text-sm">
                  <span class="min-w-0 flex-1 truncate" title={entry.client_name}>{entry.client_name}</span>
                  <span :if={entry.progress > 0} class="shrink-0 text-xs text-base-content/60">{entry.progress}%</span>
                  <span :if={entry.progress == 0 && upload_errors(@uploads.photos, entry) == []} class="shrink-0 text-xs text-base-content/60">{gettext("waiting")}</span>
                  <button type="button" phx-click="cancel" phx-value-ref={entry.ref} phx-target={@myself} class="btn btn-ghost btn-xs btn-circle" aria-label={gettext("Cancel")}>
                    <.icon name="hero-x-mark" class="h-4 w-4" />
                  </button>
                </div>
                <progress :if={entry.progress > 0 && upload_errors(@uploads.photos, entry) == []} class="progress progress-primary h-1.5 w-full" value={entry.progress} max="100"></progress>
                <p :for={error <- upload_errors(@uploads.photos, entry)} class="text-xs text-error" role="alert">
                  {Uploads.entry_error(error)}
                </p>
              </li>
            </ul>

            <%!-- Arrived, and being stored in the background: nothing to cancel any more. --%>
            <ul :if={@saving != []} id={"#{@id}-saving"} class="flex flex-col gap-1 text-sm" aria-live="polite">
              <li :for={item <- @saving} id={"#{@id}-saving-#{item.ref}"} class="flex items-center gap-2">
                <span class="min-w-0 flex-1 truncate" title={item.name}>{item.name}</span>
                <span class="flex shrink-0 items-center gap-1 text-xs text-base-content/60">
                  <span class="loading loading-spinner loading-xs"></span>
                  <%= if item.retrying do %>
                    {gettext("Saving… trying again")}
                  <% else %>
                    {gettext("Saving…")}
                  <% end %>
                </span>
              </li>
            </ul>

            <ul :if={@queued != []} class="flex flex-col gap-0.5 text-xs text-base-content/60" aria-live="polite">
              <li :for={name <- @queued} class="flex gap-2">
                <span class="min-w-0 flex-1 truncate" title={name}>{name}</span>
                <span class="shrink-0">{gettext("waiting")}</span>
              </li>
            </ul>

            <p :if={@waiting > length(@queued)} class="text-xs text-base-content/60">
              {ngettext("%{count} more file is waiting", "%{count} more files are waiting", @waiting - length(@queued))}
            </p>

            <div :if={@entries != [] || @waiting > 0} class="flex items-center gap-2">
              <button
                :if={!@upload_auto && !@started}
                type="submit"
                class="btn btn-primary btn-sm"
              >
                {ngettext("Upload %{count} file", "Upload %{count} files", length(@entries) + @waiting)}
              </button>
              <button
                type="button"
                phx-click="cancel_all"
                phx-target={@myself}
                data-cancel-all
                class="btn btn-ghost btn-sm"
              >
                {gettext("Cancel all")}
              </button>
            </div>

            <div :if={@done != [] || @skipped > 0 || @unreadable > 0} class="flex flex-col gap-1 border-t border-base-300 pt-2 text-sm" aria-live="polite">
              <p class="flex flex-wrap items-center gap-x-3 gap-y-1">
                <span :if={@added > 0} class="flex items-center gap-1 text-success"><.icon name="hero-check-circle" class="h-4 w-4" />{gettext("%{count} added", count: @added)}</span>
                <span :if={@duplicates > 0} class="flex items-center gap-1 text-base-content/70"><.icon name="hero-document-duplicate" class="h-4 w-4" />{gettext("%{count} already in this library", count: @duplicates)}</span>
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

              <ul :if={@failed > 0 || @elsewhere > 0 || @duplicates > 0} class="flex flex-col gap-0.5 text-xs">
                <li :for={item <- not_added(@done)} class="flex gap-2">
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

  defp not_added(done),
    do:
      Enum.filter(
        done,
        &match?(%{outcome: {kind, _}} when kind in [:error, :elsewhere, :duplicate], &1)
      )

  defp outcome_message({:duplicate, _file}), do: gettext("already in this library")
  defp outcome_message({:elsewhere, _file}), do: gettext("already in another of your libraries")
  defp outcome_message({:error, reason}), do: Uploads.error_message(reason)
end
