defmodule PhoenixKitPhotos.Timeline do
  @moduledoc """
  The server side of the timeline: a monthly index and per-day windows
  over one storage library.

  ## Scope

  v1 is `{:library, uuid}`. A library is the partition PhoenixKit stores
  files in (`PhoenixKit.Modules.Storage.Libraries`). The caller also passes
  the current `PhoenixKit.Users.Auth.Scope`, and every file in a window is
  checked with `Libraries.can?/3` before a URL is minted.

  The fast index is `phoenix_kit_files_library_capture_date_index` on
  `(library_uuid, taken_on, taken_at)`. Months follow `taken_on`, the local
  calendar date, not the UTC instant in `taken_at`.

  ## The two shapes

  The index is a cheap aggregation — a few hundred month buckets for a
  library of any size:

      %{
        total: 184_203,
        state: :ready,
        sections: [
          %{
            id: "2018-07",
            label: "July 2018",
            count: 412,
            sum_aspect: 548.2,
            days: 19,
            days_list: [%{id: "2018-07-14", count: 20}]
          }
        ]
      }

  A window is a day or a 500-item slice of a larger day, ordered by
  `taken_at`. `label` is already translated.

  `state` is `:ready` when the index has photos. An empty library is
  `:empty`, `:processing` (an upload is not active yet), or `:backfill`
  (capture dates are still being filled in).
  """

  use Gettext, backend: PhoenixKitPhotos.Gettext
  import Ecto.Query, warn: false

  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Modules.Storage.File, as: StorageFile
  alias PhoenixKit.Modules.Storage.FileInstance
  alias PhoenixKit.Modules.Storage.Libraries
  alias PhoenixKit.RepoHelper
  alias PhoenixKit.Users.Auth.Scope

  @window_limit 500
  @thumb_min_width 200
  @preview_min_width 800

  @typedoc "A month bucket: `\"2018-07\"`."
  @type section_id :: String.t()

  @typedoc "A day window: `\"2018-07-14\"`."
  @type window_id :: String.t()

  @type scope :: {:library, String.t()}

  @type day_count :: %{id: window_id(), count: non_neg_integer()}

  @type section :: %{
          id: section_id(),
          label: String.t(),
          count: non_neg_integer(),
          sum_aspect: float(),
          days: non_neg_integer(),
          days_list: [day_count()]
        }

  @type state :: :ready | :empty | :processing | :backfill

  @type index :: %{total: non_neg_integer(), state: state(), sections: [section()]}

  @type item :: %{
          id: String.t(),
          taken_at: DateTime.t() | nil,
          w: pos_integer(),
          h: pos_integer(),
          ar: float(),
          thumb: String.t() | nil,
          preview: String.t() | nil,
          kind: :image | :video
        }

  @type window :: %{section: window_id(), items: [item()]}

  @type error :: :capture_date_unavailable | :not_found | :unauthorized

  @doc "Maximum items returned in a single window; larger days are subdivided."
  @spec window_limit() :: pos_integer()
  def window_limit, do: @window_limit

  @doc """
  The predicates every timeline query must carry, on `phoenix_kit_files`.

  `status == "active"` keeps processing and failed rows out — they have no
  variants and would render as permanently grey tiles. The dimension
  predicate keeps `ar` from blowing up the layout.

  `edit_state` is absent on purpose. A pending or failed edit occupies the
  same uuid and belongs in the grid.
  """
  @spec base_filters() :: keyword()
  def base_filters do
    [
      system_managed: false,
      trashed_at: nil,
      parent_file_uuid: nil,
      file_type: ~w(image video),
      status: "active",
      dimensions: :positive
    ]
  end

  @doc """
  Libraries the scope may open in the timeline: the system library Media,
  then the user libraries they own or belong to.

  Media does not require user libraries to be enabled. A personal library
  does.
  """
  @spec libraries(Scope.t() | nil) :: [PhoenixKit.Modules.Storage.Library.t()]
  def libraries(%Scope{} = scope) do
    media = Libraries.get_library(Libraries.media_uuid())

    personal =
      case Scope.user_uuid(scope) do
        uuid when is_binary(uuid) ->
          uuid |> Libraries.list_user_libraries() |> Enum.map(& &1.library)

        _ ->
          []
      end

    Enum.reject([media | personal], &is_nil/1)
  end

  def libraries(_scope), do: []

  @doc """
  The library the timeline opens when the caller does not name one.

  A user's default personal library when they have one, otherwise Media.
  """
  @spec default_library_uuid(Scope.t() | nil) :: String.t() | nil
  def default_library_uuid(%Scope{} = scope) do
    case Scope.user_uuid(scope) && Libraries.default_user_library(Scope.user_uuid(scope)) do
      %{uuid: uuid} -> uuid
      _ -> Libraries.media_uuid()
    end
  end

  def default_library_uuid(_scope), do: nil

  @doc """
  Monthly index for one library.

  Live aggregation, grouped by `taken_on`. A photo taken late in the evening
  whose UTC instant falls on the next day stays in the month of `taken_on`.
  """
  @spec index(scope(), Scope.t() | nil) :: {:ok, index()} | {:error, error()}
  def index({:library, library_uuid}, auth) when is_binary(library_uuid) do
    with :ok <- capture_dates(),
         :ok <- known_library(library_uuid),
         :ok <- reader(auth) do
      days = library_uuid |> visible(auth) |> day_rows()
      sections = group_days(days)
      total = Enum.reduce(sections, 0, &(&1.count + &2))

      {:ok,
       %{
         total: total,
         state: state(total, library_uuid, auth),
         sections: sections
       }}
    end
  end

  def index(_scope, _auth), do: {:error, :unauthorized}

  @doc """
  One day of items for a library, at most `window_limit/0`, ordered by
  `taken_at`.

  Thumbnail and preview URLs come from `Storage.variant_for/2` (a crop and
  an aspect-preserving size). The original is never used as a tile. Each
  URL is minted with `Storage.authorized_url/4`, which refuses a file the
  scope may not read.
  """
  @spec window(scope(), window_id(), Scope.t() | nil) ::
          {:ok, window()} | {:error, error()}
  def window({:library, library_uuid}, day, auth) when is_binary(library_uuid) do
    with :ok <- capture_dates(),
         :ok <- known_library(library_uuid),
         :ok <- reader(auth),
         {:ok, date, offset} <- parse_window(day) do
      items =
        library_uuid
        |> visible(auth)
        |> where([f], f.taken_on == ^date)
        |> order_by([f], asc: f.taken_at, asc: f.uuid)
        |> offset(^offset)
        |> limit(@window_limit)
        |> preload(instances: ^completed_instances())
        |> repo().all()
        |> Enum.filter(&Libraries.can?(auth, &1, :read))
        |> Enum.map(&to_item(&1, auth))

      {:ok, %{section: day, items: items}}
    end
  end

  def window(_scope, _day, _auth), do: {:error, :unauthorized}

  @doc "Read-authorized data for PhoenixKit's existing canvas viewer."
  def viewer_file({:library, library_uuid}, uuid, auth) when is_binary(library_uuid) do
    with {:ok, uuid} <- Ecto.UUID.cast(uuid),
         :ok <- reader(auth),
         %StorageFile{} = file <-
           library_uuid
           |> visible(auth)
           |> where([f], f.uuid == ^uuid)
           |> preload(instances: ^completed_instances())
           |> repo().one(),
         true <- Libraries.can?(auth, file, :read) do
      urls =
        Map.new(file.instances, fn instance ->
          {instance.variant_name,
           Storage.authorized_url(auth, file, instance.variant_name, version: instance)}
        end)

      {:ok,
       %{
         file_uuid: file.uuid,
         filename: file.original_file_name || file.file_name,
         file_type: file.file_type,
         mime_type: file.mime_type,
         size: file.size || 0,
         inserted_at: file.inserted_at,
         width: file.width,
         height: file.height,
         urls: urls
       }}
    else
      _ -> {:error, :not_found}
    end
  end

  def viewer_file(_library, _uuid, _auth), do: {:error, :not_found}

  @doc """
  Folds per-day counts into month sections.

  `taken_on` decides the month. The label is translated before it reaches
  the hook.
  """
  @spec group_days([%{taken_on: Date.t(), count: non_neg_integer(), sum_aspect: number()}]) ::
          [section()]
  def group_days(day_rows) do
    day_rows
    |> Enum.group_by(&month_id(&1.taken_on))
    |> Enum.sort_by(fn {id, _} -> id end)
    |> Enum.map(fn {id, days} ->
      days = Enum.sort_by(days, & &1.taken_on, Date)

      %{
        id: id,
        label: month_label(id),
        count: Enum.reduce(days, 0, &(&1.count + &2)),
        sum_aspect: days |> Enum.reduce(0.0, &(&2 + to_float(&1.sum_aspect))),
        days: length(days),
        days_list: Enum.flat_map(days, &day_windows/1)
      }
    end)
  end

  @doc "Already-translated month heading for a `\"2018-07\"` section id."
  @spec month_label(section_id()) :: String.t()
  def month_label(<<year::binary-size(4), "-", month::binary-size(2)>>) do
    month_name(month) <> " " <> year
  end

  def month_label(other), do: to_string(other)

  defp month_name("01"), do: gettext("January")
  defp month_name("02"), do: gettext("February")
  defp month_name("03"), do: gettext("March")
  defp month_name("04"), do: gettext("April")
  defp month_name("05"), do: gettext("May")
  defp month_name("06"), do: gettext("June")
  defp month_name("07"), do: gettext("July")
  defp month_name("08"), do: gettext("August")
  defp month_name("09"), do: gettext("September")
  defp month_name("10"), do: gettext("October")
  defp month_name("11"), do: gettext("November")
  defp month_name("12"), do: gettext("December")
  defp month_name(_other), do: gettext("Unknown")

  defp month_id(%Date{year: year, month: month}) do
    :io_lib.format("~4..0B-~2..0B", [year, month]) |> IO.iodata_to_binary()
  end

  defp day_rows(query) do
    query
    |> where([f], not is_nil(f.taken_on))
    |> group_by([f], f.taken_on)
    |> order_by([f], asc: f.taken_on)
    |> select([f], %{
      taken_on: f.taken_on,
      count: count(f.uuid),
      sum_aspect:
        fragment(
          "coalesce(sum(?::double precision / nullif(?, 0)), 0)",
          f.width,
          f.height
        )
    })
    |> repo().all()
  end

  defp state(total, _library_uuid, _auth) when total > 0, do: :ready

  defp state(0, library_uuid, auth) do
    cond do
      processing?(library_uuid, auth) -> :processing
      backfill?(library_uuid, auth) -> :backfill
      true -> :empty
    end
  end

  # An upload that has not become active yet. Same ownership and the same
  # row exclusions as the grid, but status is still "processing", so it has
  # no variants and must not occupy a cell.
  defp processing?(library_uuid, auth) do
    StorageFile
    |> where([f], f.library_uuid == ^library_uuid)
    |> where([f], f.system_managed == false)
    |> where([f], is_nil(f.trashed_at))
    |> where([f], is_nil(f.parent_file_uuid))
    |> where([f], f.file_type in ["image", "video"])
    |> where([f], f.status == "processing")
    |> restrict(library_uuid, auth)
    |> repo().exists?()
  end

  defp day_windows(%{taken_on: date, count: count}) do
    day = Date.to_iso8601(date)

    if count > 0 do
      for offset <- 0..(count - 1)//@window_limit do
        %{
          id: if(offset == 0, do: day, else: "#{day}:#{offset}"),
          count: min(@window_limit, count - offset)
        }
      end
    else
      []
    end
  end

  defp parse_window(window) when is_binary(window) do
    case String.split(window, ":") do
      [day] ->
        parse_window(day <> ":0")

      [day, offset] ->
        with {:ok, date} <- Date.from_iso8601(day),
             {offset, ""}
             when offset >= 0 and offset <= 2_147_483_647 and rem(offset, @window_limit) == 0 <-
               Integer.parse(offset) do
          {:ok, date, offset}
        else
          _ -> {:error, :not_found}
        end

      _ ->
        {:error, :not_found}
    end
  end

  defp parse_window(_), do: {:error, :not_found}

  defp backfill?(library_uuid, auth) do
    library_uuid
    |> visible(auth)
    |> where([f], is_nil(f.taken_on))
    |> repo().exists?()
  end

  defp visible(library_uuid, auth) do
    StorageFile
    |> where([f], f.library_uuid == ^library_uuid)
    |> apply_base()
    |> restrict(library_uuid, auth)
  end

  defp apply_base(query) do
    query
    |> where([f], f.system_managed == false)
    |> where([f], is_nil(f.trashed_at))
    |> where([f], is_nil(f.parent_file_uuid))
    |> where([f], f.file_type in ["image", "video"])
    |> where([f], f.status == "active")
    |> where([f], f.width > 0 and f.height > 0)
  end

  defp restrict(query, library_uuid, %Scope{} = scope) do
    cond do
      Scope.system_role?(scope) ->
        query

      readable_library?(scope, library_uuid) ->
        query

      uuid = Scope.user_uuid(scope) ->
        where(query, [f], f.user_uuid == ^uuid)

      true ->
        where(query, [f], false)
    end
  end

  defp restrict(query, _library_uuid, _scope), do: where(query, [f], false)

  # A member of a user library may read every file in it. A system library
  # (Media included) grants read only to the uploader or an Owner/Admin,
  # which `Libraries.can?/3` already encodes — Owner/Admin is handled above.
  defp readable_library?(scope, library_uuid) do
    case Libraries.get_library(library_uuid) do
      %{kind: "user", trashed_at: nil} = library ->
        Libraries.role(library, Scope.user_uuid(scope)) in [
          :owner,
          :manager,
          :contributor,
          :viewer
        ]

      _ ->
        false
    end
  end

  defp completed_instances do
    from(i in FileInstance, where: i.processing_status == "completed")
  end

  defp to_item(%StorageFile{} = file, auth) do
    thumb = variant_url(auth, file, min_width: @thumb_min_width, aspect: :crop)
    preview = variant_url(auth, file, min_width: @preview_min_width, aspect: :preserve)

    %{
      id: file.uuid,
      taken_at: file.taken_at,
      w: file.width,
      h: file.height,
      ar: file.width * 1.0 / file.height,
      thumb: thumb,
      preview: preview,
      kind: if(file.file_type == "video", do: :video, else: :image)
    }
  end

  defp variant_url(auth, %StorageFile{instances: instances} = file, opts) do
    case Storage.variant_for(file, opts) do
      "original" ->
        nil

      name when is_binary(name) ->
        instance = Enum.find(instances || [], &(&1.variant_name == name))
        url_opts = if instance, do: [version: instance], else: []
        Storage.authorized_url(auth, file, name, url_opts)
    end
  end

  defp capture_dates do
    case repo().query("SELECT taken_on FROM phoenix_kit_files LIMIT 0", []) do
      {:ok, _} ->
        :ok

      {:error, %Postgrex.Error{postgres: %{code: :undefined_column}}} ->
        {:error, :capture_date_unavailable}

      {:error, other} ->
        raise "timeline could not read phoenix_kit_files: #{inspect(other)}"
    end
  end

  defp known_library(library_uuid) do
    if Libraries.get_library(library_uuid), do: :ok, else: {:error, :not_found}
  end

  defp reader(%Scope{} = scope) do
    if Scope.user_uuid(scope) || Scope.system_role?(scope), do: :ok, else: {:error, :unauthorized}
  end

  defp reader(_scope), do: {:error, :unauthorized}

  defp to_float(%Decimal{} = decimal), do: Decimal.to_float(decimal)
  defp to_float(number) when is_integer(number), do: number * 1.0
  defp to_float(number) when is_float(number), do: number
  defp to_float(nil), do: 0.0

  defp repo, do: RepoHelper.repo()
end
