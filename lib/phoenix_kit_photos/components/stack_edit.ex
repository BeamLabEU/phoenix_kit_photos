defmodule PhoenixKitPhotos.Components.StackEdit do
  @moduledoc """
  The swipe viewer's *Edit stack*: a stack's title, description and date, its cover, and
  taking a photo out of it or the stack apart. `PhoenixKitPhotos.Components.PhotoTimeline`
  holds the dialog's state and calls `open/3` and `apply/4`; core does the work
  (`PhoenixKit.Modules.Storage.Stacks`, `PhoenixKit.Modules.Storage.ManualDate`) and checks
  again who may.

  The **date** is the stack's photos' date: setting it dates them all by hand, the cover on
  the day (and, if given, at the time) chosen and the others moved with it, so the stack
  goes to its new place in the timeline. *Use the photos' own dates* is the way back.

  The dialog is a modal `<dialog>` (the `PhotoStackDialog` hook opens it), so it sits above
  the viewer and has the keys while it is open.
  """

  use Phoenix.Component
  use Gettext, backend: PhoenixKitPhotos.Gettext

  alias PhoenixKit.Modules.Storage.{FileStack, Libraries, ManualDate, Stacks}

  @doc """
  The dialog's state for `stack_uuid` seen from page `file_uuid`, or nil when the stack is
  not in the timeline's library or the person may not change it.
  """
  def open(socket, stack_uuid, file_uuid) do
    {:library, library_uuid} = socket.assigns.scope
    auth = socket.assigns.auth

    with %FileStack{library_uuid: ^library_uuid} = stack <- Stacks.get(stack_uuid),
         [cover | _] = files <-
           stack.uuid |> Stacks.files() |> Enum.filter(&is_nil(&1.trashed_at)),
         true <- Enum.all?(files, &Libraries.can?(auth, &1, :edit)) do
      local = ManualDate.local(cover)
      uuids = Enum.map(files, & &1.uuid)
      file = if file_uuid in uuids, do: file_uuid, else: cover.uuid

      %{
        stack_uuid: stack.uuid,
        title: stack.title,
        description: stack.description,
        files: uuids,
        file: file,
        cover?: file == cover.uuid,
        count: length(files),
        date: local |> NaiveDateTime.to_date() |> Date.to_iso8601(),
        time: local |> NaiveDateTime.to_time() |> Calendar.strftime("%H:%M"),
        manual?: Enum.any?(files, &(&1.taken_at_source == "manual")),
        error: nil,
        params: %{}
      }
    else
      _ -> nil
    end
  end

  @doc """
  Does `action` (`"save"`, `"reset_dates"`, `"cover"`, `"remove"`, `"unstack"`) to the stack.
  Returns `{:ok, file_uuid}`, the photo the viewer should stay on, or `{:error, message}`.
  """
  def apply("save", edit, params, auth) do
    with :ok <- save_text(edit, params, auth),
         :ok <- save_date(edit, params, auth) do
      {:ok, edit.file}
    end
  end

  def apply("reset_dates", edit, _params, auth),
    do: edit.files |> ManualDate.reset(auth) |> answer(edit)

  def apply("cover", edit, _params, auth),
    do: edit.file |> Stacks.make_cover(auth) |> answer(edit)

  def apply("remove", edit, _params, auth),
    do: edit.file |> Stacks.remove(auth) |> answer(edit)

  def apply("unstack", edit, _params, auth),
    do: edit.stack_uuid |> Stacks.unstack(auth) |> answer(edit)

  defp save_text(edit, params, auth) do
    text = %{title: params["title"], description: params["description"]}

    if text == %{title: edit.title, description: edit.description} do
      :ok
    else
      case Stacks.update(edit.stack_uuid, text, auth) do
        {:ok, _stack} -> :ok
        {:error, reason} -> {:error, message(reason)}
      end
    end
  end

  defp save_date(edit, params, auth) do
    date = params["date"] || edit.date
    time = String.trim(params["time"] || "")

    if date == edit.date and time in [edit.time, ""] do
      :ok
    else
      with {:ok, to} <- parse(date, time),
           {:ok, _files} <- ManualDate.set(edit.files, to, auth) do
        :ok
      else
        {:error, reason} -> {:error, message(reason)}
      end
    end
  end

  # A date alone keeps the cover's time of day; a time with it sets that too.
  defp parse(date, time) do
    case {Date.from_iso8601(date), time} do
      {{:ok, date}, ""} -> {:ok, date}
      {{:ok, date}, time} -> at_time(date, time)
      _ -> {:error, :bad_date}
    end
  end

  defp at_time(date, time) do
    case Time.from_iso8601(String.slice(time <> ":00", 0, 8)) do
      {:ok, time} -> NaiveDateTime.new(date, time)
      _ -> {:error, :bad_date}
    end
  end

  defp answer({:ok, _result}, edit), do: {:ok, edit.file}
  defp answer({:error, reason}, _edit), do: {:error, message(reason)}

  defp message(:implausible_date), do: gettext("That date is before 1826 or in the future.")
  defp message(:bad_date), do: gettext("That is not a date.")
  defp message(:forbidden), do: gettext("You may not change this stack.")
  defp message(:not_found), do: gettext("This stack is no longer there.")
  defp message(%Ecto.Changeset{}), do: gettext("The title or the description is too long.")
  defp message(_other), do: gettext("That could not be done.")

  attr :edit, :map, required: true
  attr :myself, :any, required: true
  attr :id, :string, required: true

  @doc "The dialog."
  def dialog(assigns) do
    assigns =
      assigns
      |> assign(:value, fn key ->
        Map.get(assigns.edit.params, Atom.to_string(key), Map.get(assigns.edit, key))
      end)

    ~H"""
    <dialog
      id={"#{@id}-stack-edit"}
      phx-hook="PhotoStackDialog"
      phx-target={@myself}
      class="modal"
      aria-labelledby={"#{@id}-stack-edit-title"}
    >
      <form
        class="modal-box max-w-md"
        phx-submit="timeline:stack_save"
        phx-target={@myself}
      >
        <h3 id={"#{@id}-stack-edit-title"} class="text-lg font-bold">
          {ngettext("Stack of 1 photo", "Stack of %{count} photos", @edit.count)}
        </h3>

        <label class="mt-4 block">
          <span class="mb-1 block text-sm">{gettext("Title")}</span>
          <input
            name="title"
            value={@value.(:title)}
            class="input w-full"
            maxlength={FileStack.max_title()}
            autocomplete="off"
          />
        </label>

        <label class="mt-3 block">
          <span class="mb-1 block text-sm">{gettext("Description")}</span>
          <textarea
            name="description"
            class="textarea w-full"
            rows="3"
            maxlength={FileStack.max_description()}
          >{@value.(:description)}</textarea>
        </label>

        <fieldset class="mt-3">
          <legend class="mb-1 text-sm">{gettext("Date")}</legend>
          <div class="flex gap-2">
            <input
              type="date"
              name="date"
              value={@value.(:date)}
              min="1826-01-01"
              class="input w-full"
              required
            />
            <input
              type="time"
              name="time"
              value={@value.(:time)}
              class="input w-32"
              aria-label={gettext("Time")}
            />
          </div>
          <p class="mt-1 text-xs text-base-content/60">
            {gettext(
              "All its photos move to this date together, keeping their order and the time between them."
            )}
          </p>
          <button
            :if={@edit.manual?}
            type="button"
            class="btn btn-link btn-xs mt-1 px-0"
            phx-click="timeline:stack_reset_dates"
            phx-target={@myself}
          >
            {gettext("Use the photos' own dates")}
          </button>
        </fieldset>

        <p :if={@edit.error} class="mt-3 text-sm text-error" role="alert">{@edit.error}</p>

        <div class="mt-4 flex flex-wrap gap-2 border-t border-base-content/10 pt-3">
          <button
            :if={!@edit.cover?}
            type="button"
            class="btn btn-ghost btn-sm"
            phx-click="timeline:stack_cover"
            phx-target={@myself}
          >
            {gettext("Make this the cover")}
          </button>
          <button
            type="button"
            class="btn btn-ghost btn-sm"
            phx-click="timeline:stack_remove"
            phx-target={@myself}
          >
            {gettext("Take this photo out")}
          </button>
          <button
            type="button"
            class="btn btn-ghost btn-sm text-error"
            phx-click="timeline:stack_unstack"
            phx-target={@myself}
          >
            {gettext("Unstack")}
          </button>
        </div>

        <div class="modal-action">
          <button
            type="button"
            class="btn btn-ghost"
            phx-click="timeline:stack_edit_close"
            phx-target={@myself}
          >
            {gettext("Cancel")}
          </button>
          <button type="submit" class="btn btn-primary">{gettext("Save")}</button>
        </div>
      </form>
    </dialog>
    """
  end
end
