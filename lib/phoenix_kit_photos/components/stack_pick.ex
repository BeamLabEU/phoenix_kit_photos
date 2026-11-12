defmodule PhoenixKitPhotos.Components.StackPick do
  @moduledoc """
  Choosing a stack to add photos to: the library's stacks (`PhoenixKitPhotos.Timeline.stacks/3`),
  the most recently changed first, found by title.

  `choices/1` is the list, in the selection bar's *Add to a stack* dialog and in the swipe
  viewer's. `open/2`, `search/2`, `add/3` and `dialog/1` are the viewer's *Add to stack*: one
  photo, into a stack the person picks, after which the viewer follows the photo to its new
  place. `PhoenixKitPhotos.Components.PhotoTimeline` holds the state; core does the work
  (`PhoenixKit.Modules.Storage.Stacks.add/3`) and checks again who may.

  The viewer's dialog is a modal `<dialog>` (the `PhotoStackDialog` hook opens it), so it is
  above the viewer and has the keys while it is open.
  """

  use Phoenix.Component
  use Gettext, backend: PhoenixKitPhotos.Gettext
  import Ecto.Query, only: [from: 2]

  alias PhoenixKit.Modules.Storage.File, as: StorageFile
  alias PhoenixKit.Modules.Storage.Libraries
  alias PhoenixKit.Modules.Storage.Stacks
  alias PhoenixKit.RepoHelper
  alias PhoenixKitPhotos.Timeline

  @doc """
  The stacks to choose from in `scope` for `auth`, those titled with `query` when given; the
  stack `first` (when it is one of them) leads.
  """
  def stacks(scope, auth, query \\ nil, first \\ nil) do
    case Timeline.stacks(scope, auth, query: query, first: first) do
      {:ok, stacks} -> stacks
      {:error, _reason} -> []
    end
  end

  @doc "The one stack that files of `ids` are in, or nil (none, or more than one)."
  def stack_among(ids) do
    uuids = for id <- List.wrap(ids), {:ok, uuid} <- [Ecto.UUID.cast(id)], do: uuid

    from(f in StorageFile,
      where: f.uuid in ^uuids and not is_nil(f.stack_uuid),
      distinct: true,
      select: f.stack_uuid,
      limit: 2
    )
    |> RepoHelper.repo().all()
    |> case do
      [stack] -> stack
      _ -> nil
    end
  end

  @doc """
  The viewer's dialog for photo `file_uuid`, or nil when it is not a photo of the timeline's
  library this person may change.
  """
  def open(socket, file_uuid) do
    {:library, library_uuid} = scope = socket.assigns.scope
    auth = socket.assigns.auth

    with {:ok, uuid} <- Ecto.UUID.cast(file_uuid),
         %StorageFile{library_uuid: ^library_uuid, trashed_at: nil} = file <-
           RepoHelper.repo().get(StorageFile, uuid),
         true <- Libraries.can?(auth, file, :edit) do
      %{file: file.uuid, query: "", chosen: nil, stacks: stacks(scope, auth), error: nil}
    else
      _ -> nil
    end
  end

  @doc "The dialog with the stacks titled with what was typed, keeping the one chosen."
  def search(socket, pick, params) do
    query = params["q"] || ""

    %{
      pick
      | query: query,
        chosen: params["stack"] || pick.chosen,
        stacks: stacks(socket.assigns.scope, socket.assigns.auth, query)
    }
  end

  @doc "Adds the dialog's photo to `stack_uuid`: `:ok` or `{:error, message}`."
  def add(pick, stack_uuid, auth) do
    case Stacks.add(stack_uuid, [pick.file], auth) do
      {:ok, _stack} -> :ok
      {:error, reason} -> {:error, message(reason)}
    end
  end

  defp message(:too_many), do: gettext("That stack is full.")
  defp message(:forbidden), do: gettext("You may not change that stack.")
  defp message(:not_found), do: gettext("That stack is no longer there.")
  defp message(:mixed_libraries), do: gettext("That stack is in another library.")
  defp message(_other), do: gettext("That could not be done.")

  attr :stacks, :list, required: true
  attr :chosen, :string, default: nil
  attr :query, :string, default: ""

  @doc "The stacks as choices (`name=\"stack\"`), with a box to find one by its title."
  def choices(assigns) do
    ~H"""
    <input
      type="search"
      name="q"
      value={@query}
      placeholder={gettext("Find a stack by its title")}
      aria-label={gettext("Find a stack by its title")}
      class="input input-sm mt-4 w-full"
      phx-debounce="300"
      autocomplete="off"
    />
    <p :if={@stacks == [] and @query in [nil, ""]} class="mt-3 text-sm text-base-content/70">
      {gettext("There are no stacks here yet. Choose two or more photos and make one with New stack.")}
    </p>
    <p :if={@stacks == [] and @query not in [nil, ""]} class="mt-3 text-sm text-base-content/70">
      {gettext("No stack has that in its title.")}
    </p>
    <ul :if={@stacks != []} class="mt-2 max-h-72 space-y-1 overflow-y-auto" data-stack-choices>
      <li :for={stack <- @stacks}>
        <label class="flex cursor-pointer items-center gap-3 rounded-box p-1.5 hover:bg-base-200 has-[:checked]:bg-primary/10">
          <input
            type="radio"
            name="stack"
            value={stack.id}
            checked={stack.id == @chosen}
            class="radio radio-sm"
          />
          <img
            :if={stack.thumb}
            src={stack.thumb}
            alt=""
            loading="lazy"
            class="size-12 shrink-0 rounded object-cover"
          />
          <span :if={!stack.thumb} class="size-12 shrink-0 rounded bg-base-300"></span>
          <span class="min-w-0">
            <span class="block truncate font-medium">
              {stack.title || gettext("Untitled stack")}
            </span>
            <span class="block text-xs text-base-content/60">
              {ngettext("1 photo", "%{count} photos", stack.count)}<span :if={stack.taken_at}> · {Calendar.strftime(stack.taken_at, "%Y-%m-%d")}</span>
            </span>
          </span>
        </label>
      </li>
    </ul>
    """
  end

  attr :pick, :map, required: true
  attr :myself, :any, required: true
  attr :id, :string, required: true

  @doc "The viewer's dialog."
  def dialog(assigns) do
    ~H"""
    <dialog
      id={"#{@id}-stack-pick"}
      phx-mounted={Phoenix.LiveView.JS.ignore_attributes(["open"])}
      phx-hook="PhotoStackDialog"
      data-close="timeline:pick_stack_close"
      phx-target={@myself}
      class="modal"
      aria-labelledby={"#{@id}-stack-pick-title"}
    >
      <form
        id={"#{@id}-stack-pick-form"}
        class="modal-box max-w-md"
        phx-change="timeline:pick_stack_search"
        phx-submit="timeline:pick_stack_add"
        phx-target={@myself}
      >
        <h3 id={"#{@id}-stack-pick-title"} class="text-lg font-bold">
          {gettext("Add to a stack")}
        </h3>

        <.choices stacks={@pick.stacks} chosen={@pick.chosen} query={@pick.query} />

        <p :if={@pick.error} class="mt-3 text-sm text-error" role="alert">{@pick.error}</p>

        <div class="modal-action">
          <button
            type="button"
            class="btn btn-ghost"
            phx-click="timeline:pick_stack_close"
            phx-target={@myself}
          >
            {gettext("Cancel")}
          </button>
          <button type="submit" class="btn btn-primary" disabled={@pick.stacks == []}>
            {gettext("Add")}
          </button>
        </div>
      </form>
    </dialog>
    """
  end
end
