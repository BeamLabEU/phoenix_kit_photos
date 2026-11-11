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
  | `:stack` | edit | one stack of them all (`Stacks.create/4`), titled by `"title"` |
  | `:unstack` | edit | takes apart the stacks they are in (`Stacks.unstack/2`) |

  **Stacks.** The timeline shows a stack as one tile, its cover, and a person who chooses it
  means the whole stack: `whole_stacks/2` turns each cover into all of its files before a
  plan is made. A copy or a move of a stack's files makes a stack of the copies in the
  target library, in the same order and with the same title and description.

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
  alias PhoenixKit.Modules.Storage.Stacks
  alias PhoenixKit.RepoHelper
  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKitPhotos.Uploads

  @limit 5_000
  @actions ~w(download links copy move tag trash restore stack unstack)a
  @max_tags 20
  @max_tag_length 60

  @type action ::
          :download | :links | :copy | :move | :tag | :trash | :restore | :stack | :unstack
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
          | :not_stacked

  @type refusal :: %{id: String.t(), name: String.t() | nil, reason: reason()}

  @type plan :: %{
          action: action(),
          auth: Scope.t() | nil,
          files: [StorageFile.t()],
          refused: [refusal()],
          target: Library.t() | nil,
          add: [String.t()],
          remove: [String.t()],
          title: String.t() | nil
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
  `"remove"` (lists of tags, or text with commas) for `:tag`, `"title"` for `:stack`.
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
      remove: remove,
      title: if(action == :stack, do: title(params["title"]))
    }
  end

  defp title(text) when is_binary(text) do
    case String.trim(text) do
      "" -> nil
      title -> title
    end
  end

  defp title(_text), do: nil

  @doc """
  `ids` with every file of the stacks among them in place of the one that stands for its stack,
  in the stack's order, for `action`: what a person means who chose a stack's tile. Only files
  `auth` may read come along, and only those out of the trash unless the action is `:restore`.
  `:links` gives each stack's one address, and `:stack` and `:unstack` take stacks as they are,
  so for those `ids` are left alone.
  """
  @spec whole_stacks([String.t()], action(), Scope.t() | nil) :: [String.t()]
  def whole_stacks(ids, action, _auth) when action in [:links, :stack, :unstack],
    do: clean_ids(ids)

  def whole_stacks(ids, action, auth) do
    ids = clean_ids(ids)

    stacked =
      StorageFile
      |> where([f], f.uuid in ^ids and not is_nil(f.stack_uuid))
      |> select([f], {f.uuid, f.stack_uuid})
      |> repo().all()
      |> Map.new()

    if stacked == %{},
      do: ids,
      else: expand(ids, stacked, members(Enum.uniq(Map.values(stacked)), action, auth))
  end

  # Each stack's files the person may read, in its order.
  defp members(stack_uuids, action, auth) do
    StorageFile
    |> where([f], f.stack_uuid in ^stack_uuids)
    |> where([f], f.system_managed == false and is_nil(f.parent_file_uuid))
    |> then(&if(action == :restore, do: &1, else: where(&1, [f], is_nil(f.trashed_at))))
    |> order_by([f], asc: f.stack_position, asc: f.uuid)
    |> repo().all()
    |> Enum.filter(&Libraries.can?(auth, &1, :read))
    |> Enum.group_by(& &1.stack_uuid, & &1.uuid)
  end

  defp expand(ids, stacked, members) do
    ids
    |> Enum.flat_map(fn id ->
      case stacked[id] do
        nil -> [id]
        stack -> Map.get(members, stack, [id])
      end
    end)
    |> Enum.uniq()
    |> Enum.take(@limit)
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

  defp check_action(:stack, file, rights, _target, _present) do
    if may?(rights, file, :edit), do: :ok, else: {:refused, :not_allowed}
  end

  defp check_action(:unstack, file, rights, _target, _present) do
    cond do
      is_nil(file.stack_uuid) -> {:refused, :not_stacked}
      may?(rights, file, :edit) -> :ok
      true -> {:refused, :not_allowed}
    end
  end

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
  def run(plan, opts \\ [])

  # One stack of all the plan's files: it is made whole or not at all.
  def run(%{action: :stack, files: files, auth: auth} = plan, opts) do
    uuids = Enum.map(files, & &1.uuid)

    result =
      case files != [] && Stacks.create(uuids, auth, %{title: plan[:title]}) do
        {:ok, _stack} ->
          %{action: :stack, done: uuids, failed: [], created: []}

        {:error, reason} ->
          failed = Enum.map(files, &refusal(&1.uuid, &1, stack_failure(reason)))
          %{action: :stack, done: [], failed: failed, created: []}

        false ->
          %{action: :stack, done: [], failed: [], created: []}
      end

    log(plan, result, opts)
    result
  end

  # Each stack among the files, taken apart once.
  def run(%{action: :unstack, files: files, auth: auth} = plan, opts) do
    result =
      files
      |> Enum.group_by(& &1.stack_uuid)
      |> Enum.reduce(%{action: :unstack, done: [], failed: [], created: []}, fn {stack, chosen},
                                                                                acc ->
        case Stacks.unstack(stack, auth) do
          {:ok, uuids} ->
            %{acc | done: acc.done ++ uuids}

          {:error, reason} ->
            failed = Enum.map(chosen, &refusal(&1.uuid, &1, stack_failure(reason)))
            %{acc | failed: acc.failed ++ failed}
        end
      end)

    log(plan, result, opts)
    result
  end

  def run(%{action: action, files: files} = plan, opts) do
    progress = Keyword.get(opts, :on_progress, fn _done, _total -> :ok end)
    total = length(files)

    result =
      files
      |> Enum.with_index(1)
      |> Enum.reduce(%{action: action, done: [], failed: [], created: [], pairs: []}, fn {file,
                                                                                          at},
                                                                                         acc ->
        acc = record(acc, file, apply_safely(plan, file))
        progress.(at, total)
        acc
      end)

    if action in [:copy, :move], do: restack(plan, files, Map.new(result.pairs))

    result = Map.delete(result, :pairs)
    log(plan, result, opts)

    %{
      result
      | done: Enum.reverse(result.done),
        failed: Enum.reverse(result.failed),
        created: Enum.reverse(result.created)
    }
  end

  defp stack_failure(:forbidden), do: :not_allowed
  defp stack_failure(:not_found), do: :not_found
  defp stack_failure(:not_stackable), do: :trashed
  defp stack_failure(reason) when reason in [:too_few, :too_many, :mixed_libraries], do: reason
  defp stack_failure(_other), do: :failed

  # Copies of a stack's files are a stack in the target library too: in the order of the
  # original, with its title and description. A stack of which fewer than two files were
  # copied has nothing to stack. Failing to stack leaves the copies as single files.
  # `copies` maps a file's uuid to its copy's.
  @doc false
  def restack(%{auth: auth}, files, copies) do
    files
    |> Enum.reject(&is_nil(&1.stack_uuid))
    |> Enum.group_by(& &1.stack_uuid)
    |> Enum.each(fn {stack_uuid, members} ->
      copied =
        members
        |> Enum.sort_by(&{&1.stack_position, &1.uuid})
        |> Enum.map(&copies[&1.uuid])
        |> Enum.reject(&is_nil/1)

      with [_, _ | _] <- copied,
           %{} = stack <- Stacks.get(stack_uuid),
           {:error, reason} <-
             Stacks.create(copied, auth, %{title: stack.title, description: stack.description},
               keep_order: true
             ) do
        Logger.warning("Photos: could not stack the copies of #{stack_uuid}: #{inspect(reason)}")
      end
    end)
  rescue
    error ->
      Logger.warning("Photos: could not stack copies: #{Exception.message(error)}")
      :ok
  end

  defp record(acc, file, {:ok, %StorageFile{uuid: created}})
       when created != file.uuid do
    %{
      acc
      | done: [file.uuid | acc.done],
        created: [created | acc.created],
        pairs: [{file.uuid, created} | acc.pairs]
    }
  end

  defp record(acc, file, {:ok, _result}), do: %{acc | done: [file.uuid | acc.done]}

  defp record(acc, file, {:error, reason}) do
    failure = failure(reason)
    if failure == :failed and reason != :failed, do: log_failure(file, inspect(reason, limit: 8))
    %{acc | failed: [refusal(file.uuid, file, failure) | acc.failed]}
  end

  # One file's trouble is that file's: a row deleted since the plan, or a busy database, must not
  # stop the others or leave the person watching a progress bar that never ends. The person is
  # told one word; the log names the file and what went wrong.
  defp apply_safely(plan, file) do
    apply_to(plan, file)
  rescue
    error ->
      log_failure(file, Exception.format_banner(:error, error, __STACKTRACE__))
      {:error, :failed}
  catch
    kind, reason ->
      log_failure(file, Exception.format_banner(kind, reason, __STACKTRACE__))
      {:error, :failed}
  end

  # The start of the error is enough to know it: some carry a whole record.
  defp log_failure(file, what) do
    Logger.warning(
      "Photos: bulk action failed for file #{file.uuid}: #{String.slice(what, 0, 300)}"
    )
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
  def reason_text(:not_stacked), do: gettext("not in a stack")
  def reason_text(:too_few), do: gettext("a stack needs at least two photos")
  def reason_text(:too_many), do: gettext("too many photos for one stack")
  def reason_text(:mixed_libraries), do: gettext("not all in one library")
  def reason_text(_other), do: gettext("could not be done")

  defp repo, do: RepoHelper.repo()
end
