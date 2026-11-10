defmodule PhoenixKitPhotos.Bulk do
  @moduledoc """
  What can be done to many files at once. A person gets here through the timeline's selection
  and an agent through the API tools (`PhoenixKitPhotos.API`); both take the same two steps,
  so an agent cannot do what a person's screen would refuse.

  `plan/4` reads and writes nothing: it checks every file for the person acting and says which
  can go ahead and which cannot, and why. `run/2` does what a plan says. Nothing here trusts
  a client's list: a file the person may not read counts as one that does not exist, and a
  plan's files are read from the database, never taken from the request.

  | Action | Needs | Does |
  |---|---|---|
  | `:download` | read | nothing here: `PhoenixKitPhotos.Web.Download` streams the plan |
  | `:links` | read | nothing here: the page lists the addresses |
  | `:copy` | read, and upload in the target library | a new file in the target library |
  | `:move` | edit, and upload in the target | copy, then the original to the trash |
  | `:tag` | edit | adds tags to `metadata["tags"]`, or removes them |
  | `:trash` | edit | `Storage.trash_file/1`, which `:restore` undoes |
  | `:restore` | edit | `Storage.restore_file/1` |

  Nothing here deletes for good: a trashed file comes back with `:restore` until the site's
  trash retention empties it. A move leaves the original in the trash, and the new file has
  all it had (date, place, tags, title and description), since after the retention it is the
  only one left. An image that has been edited stays where it is: its unedited original is not
  something a new library could hold. Copying someone else's file brings only what core gives a
  stranger (`Storage.link_copy/3`), so not their tags, their place or a date they set by hand.

  Files here are the timeline's: photos and videos. `:trash` and `:move` ask the host's removal
  guard (`config :phoenix_kit, :file_removal_guard`), and anything it says is in use stays.
  """

  use Gettext, backend: PhoenixKitPhotos.Gettext
  import Ecto.Query, warn: false
  require Logger

  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Modules.Storage.CaptureDate
  alias PhoenixKit.Modules.Storage.File, as: StorageFile
  alias PhoenixKit.Modules.Storage.Libraries
  alias PhoenixKit.Modules.Storage.Library
  alias PhoenixKit.Modules.Storage.Quotas
  alias PhoenixKit.RepoHelper
  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKitPhotos.Uploads

  @limit 5_000
  @actions ~w(download links copy move tag trash restore)a
  @max_tags 20
  @max_tag_length 60

  @type action :: :download | :links | :copy | :move | :tag | :trash | :restore
  @type reason ::
          :not_found
          | :not_allowed
          | :same_library
          | :already_there
          | :not_trashed
          | :trashed
          | :no_target
          | :edited
          | :in_use

  @type refusal :: %{id: String.t(), name: String.t() | nil, reason: reason()}

  @type plan :: %{
          action: action(),
          auth: Scope.t() | nil,
          files: [StorageFile.t()],
          refused: [refusal()],
          target: Library.t() | nil,
          add: [String.t()],
          remove: [String.t()]
        }

  @doc "The most files one action takes."
  @spec limit() :: pos_integer()
  def limit, do: @limit

  @doc "The action named by a client's string, or nil."
  @spec action(term()) :: action() | nil
  def action(name) when is_binary(name), do: Enum.find(@actions, &(Atom.to_string(&1) == name))
  def action(_name), do: nil

  @doc """
  Checks `ids` for `action` by `auth`.

  `params` holds what the action needs: `"library"` (a uuid) for `:copy` and `:move`, `"add"` and
  `"remove"` (lists of tags, or text with commas) for `:tag`.
  """
  @spec plan(action(), [String.t()], Scope.t() | nil, map()) :: plan()
  def plan(action, ids, auth, params \\ %{}) when action in @actions do
    ids = clean_ids(ids)
    found = load(ids)
    by_id = Map.new(found, &{&1.uuid, &1})
    target = target(action, params, auth)
    present = existing_checksums(action, target, found)
    rights = found |> rights(auth) |> Map.put(:in_use, in_use(action, found, auth))

    {files, refused} =
      Enum.reduce(ids, {[], []}, fn id, {files, refused} ->
        case check(action, Map.get(by_id, id), rights, target, present) do
          :ok -> {[by_id[id] | files], refused}
          {:refused, reason} -> {files, [refusal(id, by_id[id], reason) | refused]}
        end
      end)

    {add, remove} = tag_changes(action, params)

    %{
      action: action,
      auth: auth,
      files: Enum.reverse(files),
      refused: Enum.reverse(refused),
      target: target,
      add: add,
      remove: remove
    }
  end

  defp refusal(id, nil, reason), do: %{id: id, name: nil, reason: reason}

  defp refusal(id, %StorageFile{} = file, reason),
    do: %{id: id, name: file.original_file_name || file.file_name, reason: reason}

  defp clean_ids(ids) do
    ids
    |> List.wrap()
    |> Enum.flat_map(fn id ->
      case is_binary(id) && Ecto.UUID.cast(id) do
        {:ok, uuid} -> [uuid]
        _ -> []
      end
    end)
    |> Enum.uniq()
    |> Enum.take(@limit)
  end

  defp load([]), do: []

  defp load(ids) do
    StorageFile
    |> where([f], f.uuid in ^ids)
    |> where([f], f.system_managed == false and is_nil(f.parent_file_uuid))
    |> where([f], f.file_type in ["image", "video"] and f.status in ["active", "trashed"])
    |> repo().all()
  end

  # What a person may do to a file follows from its library and its uploader, and a selection
  # of thousands has few of those: ask once for each pair, not three queries for each file.
  defp rights(files, auth) do
    files
    |> Enum.uniq_by(&right_key/1)
    |> Map.new(fn file ->
      {right_key(file),
       %{read: Libraries.can?(auth, file, :read), edit: Libraries.can?(auth, file, :edit)}}
    end)
  end

  defp right_key(file), do: {file.library_uuid, file.user_uuid}

  defp may?(rights, file, right), do: rights |> Map.fetch!(right_key(file)) |> Map.fetch!(right)

  # What the host says is in use somewhere the library knows nothing about. Its guard is asked
  # once for the lot; one that fails counts as a no, for everything.
  defp in_use(action, files, auth) when action in [:trash, :move] and files != [] do
    case Application.get_env(:phoenix_kit, :file_removal_guard) do
      nil ->
        MapSet.new()

      guard ->
        ctx = %{scope: auth, action: :trash_file, folder_uuid: nil}
        ask_guard(guard, Enum.map(files, & &1.uuid), ctx)
    end
  end

  defp in_use(_action, _files, _auth), do: MapSet.new()

  # As core's media browser asks it: in a process of its own, so one that hangs or dies cannot
  # hold or take down the page; under `:file_removal_guard_timeout` (ms); uuids compared in lower
  # case. Anything but a list of places for files that were asked about fails closed.
  defp ask_guard(guard, uuids, ctx) do
    everything = MapSet.new(uuids)
    asked = Map.new(uuids, &{String.downcase(&1), &1})

    with {:ok, places} when is_list(places) <- call_guard(fn -> guard.places(uuids, ctx) end),
         {:ok, used} <- read_places(places, asked) do
      used
    else
      _failed ->
        Logger.error("Photos: removal guard #{inspect(guard)} failed; treating all as in use")
        everything
    end
  end

  defp read_places(places, asked) do
    Enum.reduce_while(places, {:ok, MapSet.new()}, fn
      %{file_uuid: uuid}, {:ok, used} when is_binary(uuid) ->
        case Map.fetch(asked, String.downcase(uuid)) do
          {:ok, original} -> {:cont, {:ok, MapSet.put(used, original)}}
          :error -> {:halt, :error}
        end

      _other, _acc ->
        {:halt, :error}
    end)
  end

  defp call_guard(fun) do
    parent = self()
    ref = make_ref()
    callers = [parent | Process.get(:"$callers", [])]

    {pid, monitor} =
      spawn_monitor(fn ->
        Process.put(:"$callers", callers)

        result =
          try do
            {:ok, fun.()}
          rescue
            _error -> :error
          catch
            _kind, _reason -> :error
          end

        send(parent, {ref, result})
      end)

    receive do
      {^ref, result} ->
        Process.demonitor(monitor, [:flush])
        result

      {:DOWN, ^monitor, :process, ^pid, _reason} ->
        :error
    after
      guard_timeout() ->
        Process.exit(pid, :kill)
        Process.demonitor(monitor, [:flush])

        receive do
          {^ref, _late} -> :ok
        after
          0 -> :ok
        end

        :error
    end
  end

  defp guard_timeout do
    case Application.get_env(:phoenix_kit, :file_removal_guard_timeout, 5_000) do
      ms when is_integer(ms) and ms > 0 -> ms
      _other -> 5_000
    end
  end

  defp used?(rights, file), do: MapSet.member?(rights.in_use, file.uuid)

  defp check(_action, nil, _rights, _target, _present), do: {:refused, :not_found}

  defp check(action, %StorageFile{} = file, rights, target, present) do
    if may?(rights, file, :read),
      do: check_action(action, file, rights, target, present),
      else: {:refused, :not_found}
  end

  defp check_action(action, file, _rights, _target, _present)
       when action in [:download, :links] do
    if is_nil(file.trashed_at), do: :ok, else: {:refused, :trashed}
  end

  defp check_action(:restore, file, rights, _target, _present) do
    cond do
      is_nil(file.trashed_at) -> {:refused, :not_trashed}
      may?(rights, file, :edit) -> :ok
      true -> {:refused, :not_allowed}
    end
  end

  defp check_action(_action, %{trashed_at: at}, _rights, _target, _present) when not is_nil(at),
    do: {:refused, :trashed}

  defp check_action(:tag, file, rights, _target, _present) do
    if may?(rights, file, :edit), do: :ok, else: {:refused, :not_allowed}
  end

  defp check_action(:trash, file, rights, _target, _present) do
    cond do
      not may?(rights, file, :edit) -> {:refused, :not_allowed}
      used?(rights, file) -> {:refused, :in_use}
      true -> :ok
    end
  end

  defp check_action(_copy_or_move, _file, _rights, nil, _present), do: {:refused, :no_target}

  defp check_action(action, file, rights, target, present) do
    with :ok <- check_target(file, target),
         :ok <- if(action == :move, do: check_move(file, rights), else: :ok) do
      if Map.has_key?(present, file.file_checksum),
        do: {:refused, :already_there},
        else: :ok
    end
  end

  defp check_target(file, target) do
    if to_string(file.library_uuid) == to_string(target.uuid),
      do: {:refused, :same_library},
      else: :ok
  end

  # What a move asks beyond a copy: the file leaves its library, so it must be the person's to
  # take, unedited, and used by nothing there.
  defp check_move(file, rights) do
    cond do
      not may?(rights, file, :edit) -> {:refused, :not_allowed}
      edited?(file) -> {:refused, :edited}
      used?(rights, file) -> {:refused, :in_use}
      true -> :ok
    end
  end

  defp edited?(%StorageFile{edits: edits, edit_revision: revision}),
    do: edits not in [nil, %{}] or (revision || 0) > 0

  # The library files go to: one the person may add to, and never a module's own.
  defp target(action, params, auth) when action in [:copy, :move] do
    with uuid when is_binary(uuid) <- params["library"],
         {:ok, uuid} <- Ecto.UUID.cast(uuid),
         %Library{} = library <- Uploads.library(uuid),
         false <- Libraries.managed?(library) or Libraries.hidden?(library),
         true <- Uploads.can_upload?(auth, uuid) do
      library
    else
      _ -> nil
    end
  end

  defp target(_action, _params, _auth), do: nil

  # What the target library already holds of these files: copying again would only make twins.
  defp existing_checksums(action, %Library{uuid: uuid}, found) when action in [:copy, :move] do
    checksums = found |> Enum.map(& &1.file_checksum) |> Enum.reject(&is_nil/1) |> Enum.uniq()

    StorageFile
    |> where([f], f.library_uuid == ^uuid and is_nil(f.trashed_at))
    |> where([f], f.system_managed == false and is_nil(f.parent_file_uuid))
    |> where([f], f.file_checksum in ^checksums)
    |> select([f], f.file_checksum)
    |> repo().all()
    |> Map.new(&{&1, true})
  end

  defp existing_checksums(_action, _target, _found), do: %{}

  defp tag_changes(:tag, params), do: {tags(params["add"]), tags(params["remove"])}
  defp tag_changes(_action, _params), do: {[], []}

  @doc """
  Tags as a list: from a list or from text with commas, trimmed, without doubles, at most 20 of
  at most 60 characters.
  """
  @spec tags(term()) :: [String.t()]
  def tags(value) when is_binary(value), do: value |> String.split(",") |> tags()

  def tags(value) when is_list(value) do
    value
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&(&1 |> String.trim() |> String.slice(0, @max_tag_length)))
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
    |> Enum.take(@max_tags)
  end

  def tags(_value), do: []

  @doc """
  A hash of the values a plan would touch, for a confirmation that must fail when they changed:
  the same for the same data, whatever order the ids came in, and untouched by what the action
  does not depend on (a new tag does not void a confirmed trash).
  """
  @spec fingerprint(plan()) :: String.t()
  def fingerprint(%{action: action, files: files} = plan) do
    rows = files |> Enum.map(&touched(action, &1)) |> Enum.sort() |> Enum.join("\n")
    target = plan.target && plan.target.uuid
    head = Enum.join([action, target, Enum.join(plan.add, ","), Enum.join(plan.remove, ",")], "|")

    :sha256
    |> :crypto.hash(head <> "\n" <> rows)
    |> Base.url_encode64(padding: false)
  end

  defp touched(:tag, file),
    do: "#{file.uuid}|#{Enum.join(List.wrap(get_in(file.metadata || %{}, ["tags"])), ",")}"

  defp touched(action, file) when action in [:copy, :move],
    do: "#{file.uuid}|#{file.library_uuid}|#{file.file_checksum}|#{file.trashed_at}"

  defp touched(_action, file), do: "#{file.uuid}|#{file.library_uuid}|#{file.trashed_at}"

  @doc """
  Does what the plan says. Each file stands alone: one that fails is reported and the rest go
  on. `:on_progress` is called with how many are done and how many there are.
  """
  @spec run(plan(), keyword()) :: %{
          action: action(),
          done: [String.t()],
          failed: [refusal()],
          created: [String.t()]
        }
  def run(%{action: action, files: files} = plan, opts \\ []) do
    progress = Keyword.get(opts, :on_progress, fn _done, _total -> :ok end)
    total = length(files)

    result =
      files
      |> Enum.with_index(1)
      |> Enum.reduce(%{action: action, done: [], failed: [], created: []}, fn {file, at}, acc ->
        acc = record(acc, file, apply_safely(plan, file))
        progress.(at, total)
        acc
      end)

    log(plan, result, opts)

    %{
      result
      | done: Enum.reverse(result.done),
        failed: Enum.reverse(result.failed),
        created: Enum.reverse(result.created)
    }
  end

  defp record(acc, file, {:ok, %StorageFile{uuid: created}})
       when created != file.uuid do
    %{acc | done: [file.uuid | acc.done], created: [created | acc.created]}
  end

  defp record(acc, file, {:ok, _result}), do: %{acc | done: [file.uuid | acc.done]}

  defp record(acc, file, {:error, reason}) do
    %{acc | failed: [refusal(file.uuid, file, failure(reason)) | acc.failed]}
  end

  # One file's trouble is that file's: a row deleted since the plan, or a busy database, must not
  # stop the others or leave the person watching a progress bar that never ends.
  defp apply_safely(plan, file) do
    apply_to(plan, file)
  rescue
    _error -> {:error, :failed}
  catch
    _kind, _reason -> {:error, :failed}
  end

  # The file's own failure, in terms a person can be told; anything else is one word.
  defp failure(:quota_exceeded), do: :quota_exceeded
  defp failure(:managed), do: :not_allowed
  defp failure(:incompatible), do: :incompatible
  defp failure(_other), do: :failed

  defp apply_to(%{action: :trash}, file), do: Storage.trash_file(file)
  defp apply_to(%{action: :restore}, file), do: Storage.restore_file(file)

  defp apply_to(%{action: :tag, add: add, remove: remove}, file) do
    case Storage.update_file_metadata(file, &change_tags(&1, add, remove)) do
      {:ok, _file} = done -> done
      :unchanged -> {:ok, file}
      {:error, _reason} = error -> error
    end
  end

  defp apply_to(%{action: :copy} = plan, file) do
    with {:ok, copy} <- copy(plan, file) do
      carry(plan, file, copy)
    end
  end

  defp apply_to(%{action: :move} = plan, file) do
    with {:ok, copy} <- copy(plan, file),
         {:ok, copy} <- carry(plan, file, copy),
         {:ok, _original} <- Storage.trash_file(file) do
      {:ok, copy}
    end
  end

  defp change_tags(metadata, add, remove) do
    before = List.wrap(metadata["tags"])
    tags = Enum.uniq(before ++ add) -- remove
    if tags == before, do: :unchanged, else: Map.put(metadata, "tags", tags)
  end

  # Sharing the stored objects needs no bytes moved. Libraries placed differently (a user's own
  # bucket, say) cannot share, and the file is stored again.
  defp copy(%{target: target, auth: auth}, file) do
    with :ok <- check_room(target.uuid, file.size || 0) do
      case Storage.link_copy(file, Scope.user_uuid(auth), library_uuid: target.uuid) do
        {:error, reason} when reason in [:incompatible, :donor_unavailable] ->
          store_again(file, auth, target)

        other ->
          other
      end
    end
  end

  # Quotas are newer than the oldest core this package runs on.
  defp check_room(library_uuid, bytes) do
    if Code.ensure_loaded?(Quotas), do: Quotas.check_upload(library_uuid, bytes), else: :ok
  end

  # What core's copy leaves behind. A move is the same photo in a new place, and so is a copy of
  # one's own, so it all comes along: the date, the place, the tags and the text. Of someone else's
  # file a copy gets what core gives a stranger, but it must have some date or the timeline, which
  # places everything by date, would never show it.
  @doc false
  def carry(%{action: action, auth: auth}, file, copy) do
    if action == :move or to_string(file.user_uuid) == Scope.user_uuid(auth),
      do: carry_all(file, copy),
      else: date_if_missing(copy)
  end

  defp carry_all(file, copy) do
    # A burn's fingerprint describes pictures the copy does not share.
    metadata = Map.reject(file.metadata || %{}, fn {key, _} -> String.contains?(key, "burn") end)
    attrs = Map.take(file, CaptureDate.fields() ++ [:latitude, :longitude])

    with {:ok, copy} <- Storage.update_file(copy, attrs) do
      copy
      |> StorageFile.details_changeset(%{metadata: metadata, data: file.data || %{}})
      |> repo().update()
    end
  end

  defp date_if_missing(%StorageFile{taken_on: nil} = copy) do
    now = DateTime.utc_now(:second)

    Storage.update_file(copy, %{
      taken_on: DateTime.to_date(now),
      taken_at: now,
      taken_at_offset: 0,
      taken_at_source: "inserted_at"
    })
  end

  defp date_if_missing(copy), do: {:ok, copy}

  defp store_again(file, auth, target) do
    with {:ok, path, _file} <- Storage.retrieve_file(file.uuid) do
      entry = %{client_name: file.original_file_name, client_type: file.mime_type}

      try do
        case Uploads.store(path, entry, auth, target.uuid) do
          {:added, stored} -> {:ok, stored}
          {:duplicate, stored} -> {:ok, stored}
          {:elsewhere, _stored} -> {:error, :incompatible}
          {:error, _reason} = error -> error
        end
      after
        File.rm(path)
      end
    end
  end

  defp log(%{action: action}, _result, _opts) when action in [:download, :links], do: :ok
  defp log(_plan, %{done: []}, _opts), do: :ok

  defp log(%{action: action, auth: auth} = plan, result, opts) do
    PhoenixKit.Activity.log("photos", "photos.bulk_#{action}",
      actor_uuid: Scope.user_uuid(auth),
      resource_type: "file",
      metadata:
        %{
          "count" => length(result.done),
          "failed" => length(result.failed),
          "via" => Keyword.get(opts, :via, "timeline")
        }
        |> maybe_put("library", plan.target && plan.target.uuid)
        |> maybe_put("approved_by", opts[:approved_by])
    )
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  @doc "What to tell a person about a file that could not be included."
  @spec reason_text(atom()) :: String.t()
  def reason_text(:not_found), do: gettext("no longer there")
  def reason_text(:not_allowed), do: gettext("not yours to change")
  def reason_text(:same_library), do: gettext("already in this library")
  def reason_text(:already_there), do: gettext("already in that library")
  def reason_text(:not_trashed), do: gettext("not in the trash")
  def reason_text(:trashed), do: gettext("in the trash")
  def reason_text(:no_target), do: gettext("no library chosen")
  def reason_text(:edited), do: gettext("edited here, so it can be copied but not moved")
  def reason_text(:in_use), do: gettext("in use elsewhere on the site")
  def reason_text(:quota_exceeded), do: gettext("no room left in that library")
  def reason_text(:incompatible), do: gettext("that library keeps its files elsewhere")
  def reason_text(_other), do: gettext("could not be done")

  defp repo, do: RepoHelper.repo()
end
