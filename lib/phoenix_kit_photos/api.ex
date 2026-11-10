defmodule PhoenixKitPhotos.API do
  @moduledoc """
  The photo library for agents: find files by what a person would say ("the videos from last
  July"), then act on them. The write tools are `PhoenixKitPhotos.Bulk` with an API around it,
  the same two steps a person's selection takes, so every one of them answers a dry run with
  what would happen and to which files, and nothing here deletes for good.

  A key acts as its owner: `ctx.scope` is checked for each file, whatever the key's scopes say.
  """

  import Ecto.Query, warn: false

  alias PhoenixKit.API.Tool
  alias PhoenixKit.Modules.Storage.File, as: StorageFile
  alias PhoenixKit.Modules.Storage.Libraries
  alias PhoenixKit.RepoHelper
  alias PhoenixKitPhotos.Bulk
  alias PhoenixKitPhotos.Timeline
  alias PhoenixKitPhotos.Uploads

  @find_limit 500
  @batch 1_000

  @read %{read_only: true, destructive: false, idempotent: true, open_world: false}
  @write %{read_only: false, destructive: false, idempotent: true, open_world: false}

  @ids %{
    "type" => "array",
    "items" => %{"type" => "string", "minLength" => 36, "maxLength" => 36},
    "minItems" => 1,
    "maxItems" => @batch
  }
  @uuid %{"type" => "string", "minLength" => 36, "maxLength" => 36}
  @date %{"type" => "string", "minLength" => 10, "maxLength" => 10}
  @tags %{
    "type" => "array",
    "items" => %{"type" => "string", "minLength" => 1, "maxLength" => 60},
    "maxItems" => 20
  }

  @doc "The tools the module declares."
  @spec tools() :: [Tool.t()]
  def tools do
    [
      Tool.new!(
        name: "photos.list_libraries",
        audience: :admin,
        scope: "photos.files:read",
        permission: "photos",
        title: "List photo libraries",
        description:
          "The libraries the key's owner can open, each with its id, its name and whether " <>
            "they may add to it. Pass an id as `library` to the other photo tools.",
        input_schema: object(%{}),
        handler: {__MODULE__, :list_libraries},
        annotations: @read
      ),
      Tool.new!(
        name: "photos.find_files",
        audience: :admin,
        scope: "photos.files:read",
        permission: "photos",
        title: "Find photos and videos",
        description:
          "Files of one library, oldest first, narrowed by capture date (`from`, `to`, " <>
            "YYYY-MM-DD, both inclusive), `kind` (image or video), a `tag` or part of the file " <>
            "`name`. Answers at most `limit` files (default and most #{@find_limit}) and `next`, " <>
            "a cursor to pass as `after` for the following page; `next` is null at the end. A " <>
            "cursor stays good when its file is trashed or moved. Use the ids with the write " <>
            "tools.",
        input_schema:
          object(
            %{
              "library" => @uuid,
              "from" => @date,
              "to" => @date,
              "kind" => %{"type" => "string", "enum" => ["image", "video"]},
              "tag" => %{"type" => "string", "minLength" => 1, "maxLength" => 60},
              "name" => %{"type" => "string", "minLength" => 1, "maxLength" => 120},
              "limit" => %{"type" => "integer", "minimum" => 1, "maximum" => @find_limit},
              "after" => %{"type" => "string", "minLength" => 1, "maxLength" => 200}
            },
            ["library"]
          ),
        handler: {__MODULE__, :find_files},
        annotations: @read
      ),
      write(
        "photos.trash_files",
        "Move photos to the trash",
        "Moves files to the trash of their library. Nothing is deleted for good; " <>
          "`photos.restore_files` brings them back. A dry run says which files would go.",
        object(%{"ids" => @ids}, ["ids"]),
        :trash_files,
        %{@write | destructive: true}
      ),
      write(
        "photos.restore_files",
        "Restore photos from the trash",
        "Brings trashed files back to their library.",
        object(%{"ids" => @ids}, ["ids"]),
        :restore_files,
        @write
      ),
      write(
        "photos.copy_files",
        "Copy photos to a library",
        "Adds the files to another library, leaving them where they are. Files the target " <>
          "already holds are skipped.",
        object(%{"ids" => @ids, "library" => @uuid}, ["ids", "library"]),
        :copy_files,
        @write
      ),
      write(
        "photos.move_files",
        "Move photos to a library",
        "Adds the files to another library and moves the originals to the trash. Files the " <>
          "target already holds are skipped and stay where they are.",
        object(%{"ids" => @ids, "library" => @uuid}, ["ids", "library"]),
        :move_files,
        %{@write | destructive: true}
      ),
      write(
        "photos.tag_files",
        "Tag photos",
        "Adds tags to the files and removes others. A file keeps the tags not named.",
        object(%{"ids" => @ids, "add" => @tags, "remove" => @tags}, ["ids"]),
        :tag_files,
        @write
      )
    ]
  end

  defp write(name, title, description, schema, handler, annotations) do
    Tool.new!(
      name: name,
      audience: :admin,
      scope: "photos.files:write",
      permission: "photos",
      title: title,
      description: description,
      input_schema: schema,
      handler: {__MODULE__, handler},
      annotations: annotations,
      max_items: @batch
    )
  end

  defp object(properties, required \\ []) do
    %{
      "type" => "object",
      "properties" => properties,
      "required" => required,
      "additionalProperties" => false
    }
  end

  @doc false
  def list_libraries(_input, ctx) do
    libraries =
      ctx.scope
      |> Timeline.libraries()
      |> Enum.map(fn library ->
        %{
          "id" => library.uuid,
          "name" => library.name,
          "can_add" => Uploads.can_upload?(ctx.scope, library.uuid)
        }
      end)

    {:ok, %{"libraries" => libraries}}
  end

  @doc false
  def find_files(%{"library" => library} = input, ctx) do
    with {:ok, query} <- Timeline.files_query({:library, library}, ctx.scope),
         {:ok, query} <- narrow(query, input),
         {:ok, query} <- after_place(query, input["after"]) do
      limit = input["limit"] || @find_limit

      files =
        query
        |> where([f], not is_nil(f.taken_on))
        |> order_by([f], asc: f.taken_on, asc: f.taken_at, asc: f.uuid)
        |> limit(^(limit + 1))
        |> repo().all()
        |> readable(ctx.scope)

      page = Enum.take(files, limit)

      {:ok,
       %{
         "files" => Enum.map(page, &file_row/1),
         "next" => if(length(files) > limit, do: page |> List.last() |> Timeline.cursor())
       }}
    else
      {:error, :bad_date} ->
        {:error, :validation_failed, "`from` and `to` are dates, YYYY-MM-DD.", %{}}

      {:error, :bad_cursor} ->
        {:error, :validation_failed, "`after` must be a `next` from an earlier answer.", %{}}

      {:error, _reason} ->
        {:error, :not_found, "No such library.", %{}}
    end
  end

  # The query already holds back what the caller may not read; this is the second look. It asks
  # once per library and uploader, as `Bulk` does, never once per row.
  defp readable(files, scope) do
    key = &{&1.library_uuid, &1.user_uuid}

    allowed =
      files
      |> Enum.uniq_by(key)
      |> Map.new(&{key.(&1), Libraries.can?(scope, &1, :read)})

    Enum.filter(files, &Map.fetch!(allowed, key.(&1)))
  end

  defp narrow(query, input) do
    with {:ok, from} <- date(input["from"]),
         {:ok, to} <- date(input["to"]) do
      {:ok,
       query
       |> then(&if(from, do: where(&1, [f], f.taken_on >= ^from), else: &1))
       |> then(&if(to, do: where(&1, [f], f.taken_on <= ^to), else: &1))
       |> then(fn q ->
         case input["kind"] do
           nil -> q
           kind -> where(q, [f], f.file_type == ^kind)
         end
       end)
       |> then(fn q ->
         case input["tag"] do
           nil -> q
           tag -> where(q, [f], fragment("? -> 'tags' @> ?::jsonb", f.metadata, ^[tag]))
         end
       end)
       |> then(fn q ->
         case input["name"] do
           nil ->
             q

           name ->
             pattern = "%" <> String.replace(name, ~r/[\\%_]/, "\\\\\\0") <> "%"
             where(q, [f], ilike(f.original_file_name, ^pattern))
         end
       end)}
    end
  end

  defp date(nil), do: {:ok, nil}

  defp date(text) do
    case Date.from_iso8601(text) do
      {:ok, date} -> {:ok, date}
      {:error, _reason} -> {:error, :bad_date}
    end
  end

  # After a cursor: everything the timeline puts later than that place.
  defp after_place(query, nil), do: {:ok, query}

  defp after_place(query, cursor) do
    case Timeline.after_cursor(cursor) do
      {:ok, condition} -> {:ok, where(query, ^condition)}
      :error -> {:error, :bad_cursor}
    end
  end

  defp file_row(%StorageFile{} = file) do
    %{
      "id" => file.uuid,
      "name" => file.original_file_name || file.file_name,
      "kind" => file.file_type,
      "taken_on" => file.taken_on && Date.to_iso8601(file.taken_on),
      "taken_at" => file.taken_at && DateTime.to_iso8601(file.taken_at),
      "width" => file.width,
      "height" => file.height,
      "size" => file.size,
      "tags" => List.wrap(get_in(file.metadata || %{}, ["tags"]))
    }
  end

  @doc false
  def trash_files(input, ctx), do: act(:trash, input, ctx)
  @doc false
  def restore_files(input, ctx), do: act(:restore, input, ctx)
  @doc false
  def copy_files(input, ctx), do: act(:copy, input, ctx)
  @doc false
  def move_files(input, ctx), do: act(:move, input, ctx)
  @doc false
  def tag_files(input, ctx), do: act(:tag, input, ctx)

  defp act(action, input, ctx) do
    plan = Bulk.plan(action, input["ids"], ctx.scope, input)

    cond do
      action in [:copy, :move] and is_nil(plan.target) ->
        {:error, :not_found, "No such library, or the key's owner may not add to it.", %{}}

      ctx.dry_run? ->
        {:preview, preview(plan), Bulk.fingerprint(plan)}

      true ->
        result =
          Bulk.run(plan,
            via: "api",
            approved_by: Map.get(ctx, :approved_by_uuid),
            on_progress: progress(ctx)
          )

        {:ok,
         %{
           "done" => result.done,
           "created" => result.created,
           "skipped" => Enum.map(plan.refused ++ result.failed, &row_out/1)
         }}
    end
  end

  # A long batch under an approval reports as it goes, so it is not taken for dead.
  defp progress(ctx) do
    report = Map.get(ctx, :progress)

    fn done, total ->
      if is_function(report, 1) and (rem(done, 25) == 0 or done == total) do
        report.(%{"done" => done, "total" => total})
      end
    end
  end

  defp row_out(%{id: id, reason: reason}), do: %{"id" => id, "reason" => to_string(reason)}

  defp preview(plan) do
    %{
      "rows" =>
        Enum.map(plan.files, &%{"id" => &1.uuid, "name" => &1.original_file_name || &1.uuid}) ++
          Enum.map(plan.refused, fn refusal ->
            %{"id" => refusal.id, "error" => Bulk.reason_text(refusal.reason)}
          end),
      "totals" => %{"rows" => length(plan.files), "skipped" => length(plan.refused)},
      "warnings" => []
    }
  end

  defp repo, do: RepoHelper.repo()
end
