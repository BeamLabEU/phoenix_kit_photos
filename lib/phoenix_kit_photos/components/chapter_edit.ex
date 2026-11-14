defmodule PhoenixKitPhotos.Components.ChapterEdit do
  @moduledoc """
  The dialog that makes, changes and deletes a chapter (`PhoenixKitPhotos.Chapters`): its
  title, emoji, dates, colour, description and, for a sub-chapter, the chapter it is part
  of. `PhoenixKitPhotos.Components.PhotoTimeline` holds its state and calls `new/3`,
  `edit/2`, `sub/2`, `change/2` and `apply/3`; `Chapters` checks again who may.

  Made from the selection bar, it opens on the chosen photos: the first and last day they
  were taken on as start and end (one day: no end), the first of them as the cover, and the
  chapter those days are in as its parent.

  Like the stack dialog it is a modal `<dialog>` opened by the `PhotoStackDialog` hook.
  """

  use Phoenix.Component
  use Gettext, backend: PhoenixKitPhotos.Gettext

  alias PhoenixKitPhotos.Chapter
  alias PhoenixKitPhotos.Chapters

  @emoji ~w(✈️ 🏖️ 🏔️ 🚗 ⛺ 🏠 🎉 🎂 💍 👶 🎓 💼 🎄 ⚽ 🎵 ❤️ 🌍 📸)

  @doc "The emoji the dialog suggests."
  def emoji, do: @emoji

  @doc """
  A new chapter in the library, from the chosen files `ids` (may be empty). Nil when the
  person may not make chapters there.
  """
  def new(auth, library_uuid, ids) do
    if Chapters.can_edit?(auth, library_uuid) do
      chapters = Chapters.list(library_uuid)
      params = library_uuid |> Chapters.span_of(ids) |> new_params(chapters)
      state(nil, library_uuid, params, chapters, 0)
    end
  end

  # Nothing chosen (or nothing of this library): a chapter starting today.
  defp new_params(nil, chapters),
    do: new_params(%{from: Date.utc_today(), to: Date.utc_today(), first: nil}, chapters)

  defp new_params(%{from: from, to: to, first: first}, chapters) do
    parent = Chapters.containing(chapters, from, to)

    %{
      "title" => "",
      "emoji" => "",
      "description" => "",
      "color" => hd(Chapter.colors()),
      "starts_on" => Date.to_iso8601(from),
      "ends_on" => if(to != from, do: Date.to_iso8601(to), else: ""),
      "parent_uuid" => (parent && parent.uuid) || "",
      "cover_file_uuid" => first || ""
    }
  end

  @doc "A new sub-chapter of `parent_uuid`, starting on its first day."
  def sub(auth, parent_uuid) do
    with %Chapter{parent_uuid: nil} = parent <- Chapters.get(parent_uuid),
         true <- Chapters.can_edit?(auth, parent.library_uuid) do
      params = %{
        "title" => "",
        "emoji" => "",
        "description" => "",
        "color" => parent.color || hd(Chapter.colors()),
        "starts_on" => Date.to_iso8601(parent.starts_on),
        "ends_on" => "",
        "parent_uuid" => parent.uuid,
        "cover_file_uuid" => ""
      }

      state(nil, parent.library_uuid, params, Chapters.list(parent.library_uuid), 0)
    else
      _ -> nil
    end
  end

  @doc "The chapter `uuid` to change, or nil (gone, another library's, not theirs to change)."
  def edit(auth, uuid, library_uuid) do
    with %Chapter{library_uuid: ^library_uuid} = chapter <- Chapters.get(uuid),
         true <- Chapters.can_edit?(auth, library_uuid) do
      params = %{
        "title" => chapter.title,
        "emoji" => chapter.emoji || "",
        "description" => chapter.description || "",
        "color" => chapter.color || hd(Chapter.colors()),
        "starts_on" => Date.to_iso8601(chapter.starts_on),
        "ends_on" => (chapter.ends_on && Date.to_iso8601(chapter.ends_on)) || "",
        "parent_uuid" => chapter.parent_uuid || "",
        "cover_file_uuid" => chapter.cover_file_uuid || ""
      }

      state(
        chapter,
        library_uuid,
        params,
        Chapters.list(library_uuid),
        Chapters.sub_chapter_count(chapter)
      )
    else
      _ -> nil
    end
  end

  defp state(chapter, library_uuid, params, chapters, subs) do
    except = chapter && chapter.uuid

    %{
      chapter: chapter,
      library_uuid: library_uuid,
      params: params,
      parents: Enum.filter(chapters, &(is_nil(&1.parent_uuid) and &1.uuid != except)),
      sub_count: subs,
      error: nil
    }
  end

  @doc "The form changed: keep what was typed (an emoji button merges into it)."
  def change(edit, params) do
    kept = Map.take(params, Map.keys(edit.params))
    %{edit | params: Map.merge(edit.params, kept), error: nil}
  end

  @doc ~s(`"save"` or `"delete"`. `{:ok, chapter}` or `{:error, message}`.)
  def apply("save", edit, auth) do
    attrs = Map.update(edit.params, "parent_uuid", nil, &blank_to_nil/1)
    attrs = Map.update(attrs, "cover_file_uuid", nil, &blank_to_nil/1)

    result =
      case edit.chapter do
        nil -> Chapters.create(auth, edit.library_uuid, attrs)
        chapter -> Chapters.update(auth, chapter, attrs)
      end

    answer(result)
  end

  def apply("delete", %{chapter: %Chapter{} = chapter}, auth),
    do: auth |> Chapters.delete(chapter) |> answer()

  def apply(_action, _edit, _auth), do: {:error, message(:not_found)}

  defp answer({:ok, chapter}), do: {:ok, chapter}
  defp answer({:error, reason}), do: {:error, message(reason)}

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value

  @doc false
  def message(:forbidden), do: gettext("You may not change the chapters of this library.")
  def message(:not_found), do: gettext("This chapter is no longer there.")
  def message(:bad_parent), do: gettext("That chapter cannot hold a sub-chapter.")

  def message(:outside_parent),
    do: gettext("A sub-chapter's days must be inside the days of the chapter it is part of.")

  def message(:has_sub_chapters),
    do: gettext("This chapter has sub-chapters of its own, so it cannot be part of another.")

  def message(:sub_chapter_outside),
    do: gettext("Some of its sub-chapters would fall outside these days.")

  def message(%Ecto.Changeset{} = changeset) do
    cond do
      changeset.errors[:title] -> gettext("Give the chapter a title.")
      changeset.errors[:starts_on] -> gettext("Give the chapter a start date.")
      changeset.errors[:ends_on] -> gettext("The end is before the start.")
      changeset.errors[:emoji] -> gettext("That emoji is too long: one or two will do.")
      true -> gettext("The title or the description is too long.")
    end
  end

  def message(_other), do: gettext("That could not be done.")

  defp color_label("sky"), do: gettext("Sky")
  defp color_label("rose"), do: gettext("Rose")
  defp color_label("amber"), do: gettext("Amber")
  defp color_label("emerald"), do: gettext("Green")
  defp color_label("violet"), do: gettext("Violet")
  defp color_label("slate"), do: gettext("Grey")
  defp color_label(other), do: other

  attr :edit, :map, required: true
  attr :myself, :any, required: true
  attr :id, :string, required: true

  @doc "The dialog."
  def dialog(assigns) do
    assigns =
      assigns
      |> assign(:p, assigns.edit.params)
      |> assign(:emoji, @emoji)
      |> assign(:colors, Chapter.colors())
      |> assign(:sub?, assigns.edit.params["parent_uuid"] not in [nil, ""])

    ~H"""
    <dialog
      id={"#{@id}-chapter-edit"}
      phx-mounted={Phoenix.LiveView.JS.ignore_attributes(["open"])}
      phx-hook="PhotoStackDialog"
      data-close="timeline:chapter_close"
      phx-target={@myself}
      class="modal"
      aria-labelledby={"#{@id}-chapter-edit-title"}
    >
      <form
        id={"#{@id}-chapter-form"}
        class="modal-box max-w-lg"
        phx-change="timeline:chapter_change"
        phx-submit="timeline:chapter_save"
        phx-target={@myself}
      >
        <h3 id={"#{@id}-chapter-edit-title"} class="flex items-center gap-2 text-lg font-bold">
          <span class="hero-bookmark-square size-5 opacity-70" aria-hidden="true"></span>
          {cond do
            @edit.chapter && @sub? -> gettext("Edit sub-chapter")
            @edit.chapter -> gettext("Edit chapter")
            @sub? -> gettext("New sub-chapter")
            true -> gettext("New chapter")
          end}
        </h3>
        <p :if={!@edit.chapter} class="mt-1 text-sm text-base-content/60">
          {gettext(
            "Mark where something began: a trip, a move, a new job. It shows as a banner in the library."
          )}
        </p>

        <div class="mt-4 flex gap-2">
          <label class="w-20 shrink-0">
            <span class="mb-1 block text-sm">{gettext("Emoji")}</span>
            <input
              name="emoji"
              value={@p["emoji"]}
              class="input w-full text-center text-xl"
              maxlength={Chapter.max_emoji()}
              autocomplete="off"
              placeholder="✈️"
            />
          </label>
          <label class="min-w-0 flex-1">
            <span class="mb-1 block text-sm">{gettext("Title")}</span>
            <input
              name="title"
              value={@p["title"]}
              class="input w-full"
              maxlength={Chapter.max_title()}
              autocomplete="off"
              placeholder={gettext("Trip to France")}
              required
              phx-mounted={Phoenix.LiveView.JS.focus()}
            />
          </label>
        </div>
        <div class="mt-2 flex flex-wrap gap-1" role="group" aria-label={gettext("Suggested emoji")}>
          <button
            :for={emoji <- @emoji}
            type="button"
            class={[
              "btn btn-ghost btn-sm btn-square text-lg",
              @p["emoji"] == emoji && "btn-active"
            ]}
            phx-click="timeline:chapter_emoji"
            phx-value-emoji={emoji}
            phx-target={@myself}
          >
            {emoji}
          </button>
        </div>

        <div class="mt-3 grid grid-cols-2 gap-2">
          <label>
            <span class="mb-1 block text-sm">{gettext("Starts on")}</span>
            <input
              type="date"
              name="starts_on"
              value={@p["starts_on"]}
              min="1826-01-01"
              class="input w-full"
              required
            />
          </label>
          <label>
            <span class="mb-1 block text-sm">{gettext("Ends on")}</span>
            <input
              type="date"
              name="ends_on"
              value={@p["ends_on"]}
              min={@p["starts_on"]}
              class="input w-full"
            />
          </label>
        </div>
        <p class="mt-1 text-xs text-base-content/60">
          {gettext("No end date: a moment that changed things, like a move, or a trip still going.")}
        </p>

        <label :if={@edit.parents != [] and @edit.sub_count == 0} class="mt-3 block">
          <span class="mb-1 block text-sm">{gettext("Part of")}</span>
          <select name="parent_uuid" class="select w-full">
            <option value="" selected={!@sub?}>{gettext("None: a chapter of its own")}</option>
            <option
              :for={parent <- @edit.parents}
              value={parent.uuid}
              selected={@p["parent_uuid"] == parent.uuid}
            >
              {[parent.emoji, parent.title] |> Enum.reject(&(&1 in [nil, ""])) |> Enum.join(" ")}
            </option>
          </select>
        </label>
        <input
          :if={!(@edit.parents != [] and @edit.sub_count == 0)}
          type="hidden"
          name="parent_uuid"
          value={@p["parent_uuid"]}
        />

        <fieldset class="mt-3">
          <legend class="mb-1 text-sm">{gettext("Colour")}</legend>
          <div class="flex flex-wrap gap-2">
            <label
              :for={color <- @colors}
              class={["pkt-chapter-swatch", "pkt-chapter--#{color}"]}
              title={color_label(color)}
            >
              <input
                type="radio"
                name="color"
                value={color}
                checked={@p["color"] == color}
                class="sr-only"
              />
              <span class="sr-only">{color_label(color)}</span>
            </label>
          </div>
        </fieldset>

        <label class="mt-3 block">
          <span class="mb-1 block text-sm">{gettext("Description")}</span>
          <textarea
            name="description"
            class="textarea w-full"
            rows="2"
            maxlength={Chapter.max_description()}
            placeholder={gettext("Optional")}
          >{@p["description"]}</textarea>
        </label>

        <p :if={@edit.error} class="mt-3 text-sm text-error" role="alert">{@edit.error}</p>

        <div
          :if={@edit.chapter}
          class="mt-4 flex flex-wrap gap-2 border-t border-base-content/10 pt-3"
        >
          <button
            :if={!@sub?}
            type="button"
            class="btn btn-ghost btn-sm"
            phx-click="timeline:chapter_sub"
            phx-value-id={@edit.chapter.uuid}
            phx-target={@myself}
          >
            <span class="hero-plus size-4" aria-hidden="true"></span>
            {gettext("Add a sub-chapter")}
          </button>
          <button
            type="button"
            class="btn btn-ghost btn-sm text-error"
            phx-click="timeline:chapter_delete"
            phx-target={@myself}
            data-confirm={
              if @edit.sub_count > 0,
                do:
                  ngettext(
                    "Delete this chapter and its sub-chapter? The photos stay.",
                    "Delete this chapter and its %{count} sub-chapters? The photos stay.",
                    @edit.sub_count
                  ),
                else: gettext("Delete this chapter? The photos stay.")
            }
          >
            <span class="hero-trash size-4" aria-hidden="true"></span>
            {gettext("Delete")}
          </button>
        </div>

        <input type="hidden" name="cover_file_uuid" value={@p["cover_file_uuid"]} />

        <div class="modal-action">
          <button
            type="button"
            class="btn btn-ghost"
            phx-click="timeline:chapter_close"
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
