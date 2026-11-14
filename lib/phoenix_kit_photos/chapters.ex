defmodule PhoenixKitPhotos.Chapters do
  @moduledoc """
  A library's chapters (`PhoenixKitPhotos.Chapter`): what happened when, a trip to France, a
  move, shown in the timeline as a banner where it starts (`PhoenixKitPhotos.Timeline` cuts
  the months there).

  ## Who

  Anyone who may add to the library makes, changes and deletes its chapters
  (`PhoenixKitPhotos.Uploads.can_upload?/2`, the rule of stacks and dates); anyone who may see
  the library sees them, through the timeline, which checks that first.

  ## Sub-chapters

  A chapter may hold sub-chapters (`parent_uuid`), one level deep: a sub-chapter's parent is
  a chapter of the same library that is not itself a sub-chapter, and its days lie inside the
  parent's (a parent without an end bounds the start only). A chapter that has sub-chapters
  cannot become one, and its dates cannot leave one of them outside. Deleting a chapter
  deletes its sub-chapters (the database cascades).

  ## Changes

  Every change is announced on `topic/0` as `{:phoenix_kit_photos_chapters_changed,
  library_uuid}`; `PhoenixKitPhotos.LiveUpdates` passes it to the page's timelines, which read
  their index again when it is their library.
  """

  import Ecto.Query, warn: false

  alias PhoenixKit.Modules.Storage.File, as: StorageFile
  alias PhoenixKit.PubSub.Manager
  alias PhoenixKit.RepoHelper
  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKitPhotos.Chapter
  alias PhoenixKitPhotos.Uploads

  @topic "phoenix_kit_photos:chapters"

  @type error ::
          :forbidden
          | :not_found
          | :bad_parent
          | :outside_parent
          | :has_sub_chapters
          | :sub_chapter_outside
          | Ecto.Changeset.t()

  @doc "The topic every change is announced on."
  def topic, do: @topic

  @doc "Subscribes the caller to every library's chapter changes."
  def subscribe, do: Manager.subscribe(@topic)

  @doc """
  A library's chapters, by start (a chapter before its sub-chapters on the same day). Not
  checked: the caller has checked that the reader may see the library.
  """
  @spec list(String.t()) :: [Chapter.t()]
  def list(library_uuid) when is_binary(library_uuid) do
    Chapter
    |> where([c], c.library_uuid == ^library_uuid)
    |> order_by([c],
      asc: c.starts_on,
      asc: not is_nil(c.parent_uuid),
      desc_nulls_first: c.ends_on,
      asc: c.inserted_at
    )
    |> repo().all()
  rescue
    # A host that has not run the V2 migration yet: no chapters, not a broken timeline.
    Postgrex.Error -> []
  end

  def list(_library_uuid), do: []

  @doc "The chapter `uuid`, or nil."
  @spec get(String.t()) :: Chapter.t() | nil
  def get(uuid) when is_binary(uuid) do
    case Ecto.UUID.cast(uuid) do
      {:ok, uuid} -> repo().get(Chapter, uuid)
      :error -> nil
    end
  end

  def get(_uuid), do: nil

  @doc "Whether `auth` may make and change chapters in the library."
  @spec can_edit?(Scope.t() | nil, String.t()) :: boolean()
  def can_edit?(auth, library_uuid), do: Uploads.can_upload?(auth, library_uuid)

  @doc "Makes a chapter in the library."
  @spec create(Scope.t() | nil, String.t(), map()) :: {:ok, Chapter.t()} | {:error, error()}
  def create(auth, library_uuid, attrs) do
    if can_edit?(auth, library_uuid) do
      %Chapter{library_uuid: library_uuid, created_by_uuid: Scope.user_uuid(auth)}
      |> Chapter.changeset(attrs)
      |> save(&repo().insert(&1))
    else
      {:error, :forbidden}
    end
  end

  @doc "Changes a chapter."
  @spec update(Scope.t() | nil, Chapter.t(), map()) :: {:ok, Chapter.t()} | {:error, error()}
  def update(auth, %Chapter{} = chapter, attrs) do
    if can_edit?(auth, chapter.library_uuid) do
      chapter
      |> Chapter.changeset(attrs)
      |> save(&repo().update(&1))
    else
      {:error, :forbidden}
    end
  end

  @doc "Deletes a chapter, and its sub-chapters with it."
  @spec delete(Scope.t() | nil, Chapter.t()) :: {:ok, Chapter.t()} | {:error, error()}
  def delete(auth, %Chapter{} = chapter) do
    if can_edit?(auth, chapter.library_uuid) do
      case repo().delete(chapter, stale_error_field: :uuid) do
        {:ok, chapter} ->
          announce(chapter.library_uuid)
          {:ok, chapter}

        {:error, _changeset} ->
          {:error, :not_found}
      end
    else
      {:error, :forbidden}
    end
  end

  @doc "How many sub-chapters a chapter has."
  @spec sub_chapter_count(Chapter.t()) :: non_neg_integer()
  def sub_chapter_count(%Chapter{uuid: uuid}) do
    Chapter |> where([c], c.parent_uuid == ^uuid) |> repo().aggregate(:count)
  end

  @doc """
  The chapters of the library a new or changed chapter may be part of: those that are not
  sub-chapters, except `except` (the chapter being changed).
  """
  @spec parents(String.t(), String.t() | nil) :: [Chapter.t()]
  def parents(library_uuid, except \\ nil) do
    library_uuid |> list() |> Enum.filter(&(is_nil(&1.parent_uuid) and &1.uuid != except))
  end

  @doc """
  The chapter of `chapters` (not a sub-chapter, and with an end: "Moved to Tallinn" holds
  everything after it and is no trip's parent) whose days hold all of `from`..`to`, the latest
  starting one: what a new chapter made from those days is most likely part of.
  """
  @spec containing([Chapter.t()], Date.t(), Date.t()) :: Chapter.t() | nil
  def containing(chapters, %Date{} = from, %Date{} = to) do
    chapters
    |> Enum.filter(&(is_nil(&1.parent_uuid) and holds?(&1, from, to)))
    |> Enum.max_by(& &1.starts_on, Date, fn -> nil end)
  end

  @doc """
  What chosen files say about a chapter made from them: the first and the last day they were
  taken on and the first of them, among those of `library_uuid`. Nil when none is there.
  """
  @spec span_of(String.t(), [String.t()]) ::
          %{from: Date.t(), to: Date.t(), first: String.t()} | nil
  def span_of(library_uuid, file_uuids) when is_list(file_uuids) do
    ids = for id <- file_uuids, {:ok, uuid} <- [Ecto.UUID.cast(id)], do: uuid

    rows =
      StorageFile
      |> where([f], f.uuid in ^ids and f.library_uuid == ^library_uuid)
      |> where([f], not is_nil(f.taken_on) and is_nil(f.trashed_at))
      |> order_by([f], asc: f.taken_on, asc_nulls_last: f.taken_at, asc: f.uuid)
      |> select([f], {f.taken_on, f.uuid})
      |> repo().all()

    case rows do
      [] ->
        nil

      [{first_day, first} | _] ->
        {last_day, _} = List.last(rows)
        %{from: first_day, to: last_day, first: first}
    end
  end

  def span_of(_library_uuid, _file_uuids), do: nil

  # ── Saving ────────────────────────────────────────────────────────────────

  defp save(changeset, write) do
    with :ok <- valid(changeset),
         chapter = Ecto.Changeset.apply_changes(changeset),
         :ok <- check_cover(chapter),
         :ok <- check_parent(chapter),
         :ok <- check_children(chapter),
         {:ok, saved} <- write.(changeset) do
      announce(saved.library_uuid)
      {:ok, saved}
    end
  end

  defp valid(%Ecto.Changeset{valid?: true}), do: :ok
  defp valid(changeset), do: {:error, changeset}

  # A cover is a file of the library; any other is forgotten rather than refused.
  defp check_cover(%Chapter{cover_file_uuid: nil}), do: :ok

  defp check_cover(%Chapter{cover_file_uuid: cover, library_uuid: library}) do
    if repo().exists?(
         from(f in StorageFile, where: f.uuid == ^cover and f.library_uuid == ^library)
       ),
       do: :ok,
       else: {:error, :not_found}
  end

  defp check_parent(%Chapter{parent_uuid: nil}), do: :ok

  defp check_parent(%Chapter{parent_uuid: parent_uuid} = chapter) do
    case get(parent_uuid) do
      %Chapter{library_uuid: library, parent_uuid: nil} = parent
      when library == chapter.library_uuid and parent.uuid != chapter.uuid ->
        cond do
          chapter.uuid && sub_chapter_count(chapter) > 0 -> {:error, :has_sub_chapters}
          inside?(chapter, parent) -> :ok
          true -> {:error, :outside_parent}
        end

      _other ->
        {:error, :bad_parent}
    end
  end

  # A chapter's new dates must still hold its sub-chapters.
  defp check_children(%Chapter{uuid: nil}), do: :ok

  defp check_children(%Chapter{uuid: uuid} = chapter) do
    Chapter
    |> where([c], c.parent_uuid == ^uuid)
    |> repo().all()
    |> Enum.all?(&inside?(&1, chapter))
    |> if(do: :ok, else: {:error, :sub_chapter_outside})
  end

  # A sub-chapter starts on or after its chapter, and ends by its end when it has one.
  defp inside?(%Chapter{} = child, %Chapter{} = parent) do
    child_end = child.ends_on || child.starts_on

    Date.compare(child.starts_on, parent.starts_on) != :lt and
      (is_nil(parent.ends_on) or Date.compare(child_end, parent.ends_on) != :gt)
  end

  defp holds?(%Chapter{ends_on: nil}, _from, _to), do: false

  defp holds?(%Chapter{} = chapter, from, to) do
    Date.compare(from, chapter.starts_on) != :lt and Date.compare(to, chapter.ends_on) != :gt
  end

  defp announce(library_uuid) do
    Manager.broadcast(@topic, {:phoenix_kit_photos_chapters_changed, library_uuid})
    :ok
  end

  defp repo, do: RepoHelper.repo()
end
