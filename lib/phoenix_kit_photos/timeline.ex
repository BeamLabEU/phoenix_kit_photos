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
  alias PhoenixKit.Modules.Storage.Shape
  alias PhoenixKit.Modules.Storage.URLSigner
  alias PhoenixKit.RepoHelper
  alias PhoenixKit.Users.Auth.Scope

  @window_limit 500
  @slide_limit 24
  @thumb_min_width 200
  @fit_min_width 300
  @preview_min_width 800
  @large_min_width 1600

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
          fit: String.t() | nil,
          preview: String.t() | nil,
          large: String.t() | nil,
          kind: :image | :video,
          code: String.t() | nil,
          name: String.t() | nil,
          size: non_neg_integer() | nil,
          duration: non_neg_integer() | nil
        }

  @type window :: %{section: window_id(), items: [item()]}

  @typedoc """
  What the swipe viewer needs for one file: a picture (`src`), or a video
  (`poster` and `sources`). `w` and `h` are the size of the picture the viewer
  shows, never the stored size of a video (a phone clip is stored as landscape
  and played as portrait).
  """
  @type slide :: %{
          required(:id) => String.t(),
          required(:kind) => :image | :video,
          required(:w) => pos_integer(),
          required(:h) => pos_integer(),
          # The file's short code (core's `Storage.ShortCode`), what a host puts in the
          # address of the photo; nil for a file that has none yet.
          optional(:code) => String.t() | nil,
          optional(:src) => String.t() | nil,
          optional(:poster) => String.t() | nil,
          optional(:sources) => [
            %{url: String.t(), type: String.t(), role: :rendition | :original}
          ]
        }

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
  Libraries the scope may open in the timeline: the system library Media for
  someone who can manage it (`media_visible?/1`), then the user libraries they
  own or belong to.

  Media does not require user libraries to be enabled. A personal library
  does.
  """
  @spec libraries(Scope.t() | nil) :: [PhoenixKit.Modules.Storage.Library.t()]
  def libraries(%Scope{} = scope) do
    media = if media_visible?(scope), do: Libraries.get_library(Libraries.media_uuid())

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
  Whether the site's Media library is one of this scope's libraries.

  It belongs to the site, not to a person: a system role or access to the media
  module (the rule for adding to it, `Uploads.can_upload?/2`). To anyone else it
  would be an empty library they cannot add to, since a user reads only their own
  uploads there.
  """
  @spec media_visible?(Scope.t() | nil) :: boolean()
  def media_visible?(%Scope{} = scope),
    do: Scope.system_role?(scope) or Scope.has_module_access?(scope, "media")

  def media_visible?(_scope), do: false

  @doc """
  Whether a storage event about `file_uuids` can change what library `scope` shows.

  Storage announces every file event to everyone, whichever library the file is in. This
  answers from where the files are kept, trashed ones included (a trashed file leaves the
  timeline but is still a row of its library). Files that no longer exist cannot be placed, so
  they count: someone's gone for good, and the timeline asks.
  """
  @spec touches?(scope(), [String.t()]) :: boolean()
  def touches?({:library, library_uuid}, file_uuids) when is_binary(library_uuid) do
    case file_uuids |> List.wrap() |> Enum.filter(&is_binary/1) do
      [] ->
        false

      ids ->
        libraries =
          StorageFile
          |> where([f], f.uuid in ^ids)
          |> select([f], f.library_uuid)
          |> repo().all()

        libraries == [] or library_uuid in libraries
    end
  rescue
    # A value that is not a UUID, or a database that is busy: refresh rather than miss a photo.
    _error -> true
  end

  def touches?(_scope, _file_uuids), do: true

  @doc """
  The library the timeline opens when the caller does not name one.

  A user's default personal library when they have one, otherwise Media when
  they may see it (`media_visible?/1`), otherwise none.
  """
  @spec default_library_uuid(Scope.t() | nil) :: String.t() | nil
  def default_library_uuid(%Scope{} = scope) do
    case Scope.user_uuid(scope) && Libraries.default_user_library(Scope.user_uuid(scope)) do
      %{uuid: uuid} -> uuid
      _ -> if media_visible?(scope), do: Libraries.media_uuid()
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
         :ok <- reader(auth, library_uuid) do
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
  The aspect ratio of every file of a library, for the styles that show whole photos: a map
  of section id to one byte per file, in the order the timeline shows them.

  With these the browser knows the exact height of every month without fetching a single
  window, so the scrollbar and jump to month stay honest in those styles too. A byte is the
  logarithm of the ratio from 1:8 to 8:1 in 256 steps of 1.6%, which is finer than anyone can
  see in a crop and costs 260 KB for 200,000 files, once. `assets/js/layouts.js` reads it.
  """
  @spec aspects(scope(), Scope.t() | nil) ::
          {:ok, %{section_id() => binary()}} | {:error, error()}
  def aspects({:library, library_uuid}, auth) when is_binary(library_uuid) do
    with :ok <- capture_dates(),
         :ok <- known_library(library_uuid),
         :ok <- reader(auth, library_uuid) do
      rows =
        library_uuid
        |> visible(auth)
        |> where([f], not is_nil(f.taken_on))
        |> group_by([f], f.taken_on)
        |> order_by([f], asc: f.taken_on)
        |> select([f], {
          f.taken_on,
          fragment(
            """
            array_agg(
              least(255, greatest(0, round((ln(?::double precision / ?) + ?) * ?)))::smallint
              ORDER BY ? ASC, ? ASC
            )
            """,
            f.width,
            f.height,
            ^:math.log(8),
            ^(255 / (2 * :math.log(8))),
            f.taken_at,
            f.uuid
          )
        })
        |> repo().all()

      {:ok,
       rows
       |> Enum.group_by(fn {date, _bytes} -> month_id(date) end, fn {_date, bytes} -> bytes end)
       |> Map.new(fn {id, days} -> {id, days |> List.flatten() |> :binary.list_to_bin()} end)}
    end
  end

  def aspects(_scope, _auth), do: {:error, :unauthorized}

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
         :ok <- reader(auth, library_uuid),
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
        |> to_items(library_uuid, auth)

      {:ok, %{section: day, items: items}}
    end
  end

  def window(_scope, _day, _auth), do: {:error, :unauthorized}

  @doc """
  A slice of a window for the swipe viewer: `count` files (at most
  `slide_limit/0`) from position `from` of the day or day-slice `day`, in the
  order `window/3` gives them, each with full-size URLs for a screen `want`
  pixels wide.

  `from + count` may run past the end of a 500-item slice into the next one: the
  position is the same in the day, so the caller's index stays right.
  """
  @spec slides(scope(), window_id(), integer(), integer(), integer(), Scope.t() | nil) ::
          {:ok, [slide()]} | {:error, error()}
  def slides({:library, library_uuid}, day, from, count, want, auth)
      when is_binary(library_uuid) and is_integer(from) and is_integer(count) and is_integer(want) do
    with :ok <- capture_dates(),
         :ok <- known_library(library_uuid),
         :ok <- reader(auth, library_uuid),
         {:ok, date, offset} <- parse_window(day),
         true <- from >= 0 and from < @window_limit do
      want = want |> max(200) |> min(4096)

      items =
        library_uuid
        |> visible(auth)
        |> where([f], f.taken_on == ^date)
        |> order_by([f], asc: f.taken_at, asc: f.uuid)
        |> offset(^(offset + from))
        |> limit(^(count |> max(1) |> min(@slide_limit)))
        |> preload(instances: ^completed_instances())
        |> repo().all()
        |> Enum.filter(&Libraries.can?(auth, &1, :read))
        |> Enum.map(&to_slide(&1, auth, want))

      {:ok, items}
    else
      false -> {:error, :not_found}
      {:error, _} = error -> error
    end
  end

  def slides(_scope, _day, _from, _count, _want, _auth), do: {:error, :unauthorized}

  @doc """
  The ids of positions `from` to `to` of the timeline, both included, at most `limit`. With
  `:kind` (`"image"` or `"video"`) the positions are those of that kind only, and without
  `from` and `to` that is the whole library.

  This is what a selection asks when a range runs through months the browser has not fetched.
  """
  @spec ids_between(scope(), Scope.t() | nil, keyword()) ::
          {:ok, [String.t()], boolean()} | {:error, error()}
  def ids_between(scope, auth, opts) do
    limit = Keyword.fetch!(opts, :limit)
    from = max(Keyword.get(opts, :from) || 0, 0)
    to = Keyword.get(opts, :to)
    wanted = if to, do: max(to - from + 1, 0), else: limit

    with {:ok, query} <- files_query(scope, auth) do
      ids =
        query
        |> where([f], not is_nil(f.taken_on))
        |> of_kind(Keyword.get(opts, :kind))
        |> order_by([f], asc: f.taken_on, asc: f.taken_at, asc: f.uuid)
        |> offset(^from)
        |> limit(^(min(wanted, limit) + 1))
        |> select([f], f.uuid)
        |> repo().all()

      {:ok, Enum.take(ids, min(wanted, limit)),
       wanted > limit or (is_nil(to) and length(ids) > limit)}
    end
  end

  defp of_kind(query, kind) when kind in ["image", "video"],
    do: where(query, [f], f.file_type == ^kind)

  defp of_kind(query, _kind), do: query

  @doc """
  The query of what a timeline shows, for code that narrows it further (`PhoenixKitPhotos.API`).
  The library is checked for `auth`; each file of the answer still has to pass `Libraries.can?/3`.
  """
  @spec files_query(scope(), Scope.t() | nil) :: {:ok, Ecto.Query.t()} | {:error, error()}
  def files_query({:library, library_uuid}, auth) when is_binary(library_uuid) do
    with {:ok, uuid} <- cast_uuid(library_uuid),
         :ok <- capture_dates(),
         :ok <- known_library(uuid),
         :ok <- reader(auth, uuid) do
      {:ok, visible(uuid, auth)}
    end
  end

  def files_query(_scope, _auth), do: {:error, :unauthorized}

  defp cast_uuid(uuid) do
    case Ecto.UUID.cast(uuid) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, :not_found}
    end
  end

  @doc """
  A place in the timeline's order, for paging. It holds the place itself rather than naming a
  file, so a page still follows on when the file it ended on has since been trashed or moved.
  """
  @spec cursor(StorageFile.t()) :: String.t()
  def cursor(%StorageFile{taken_on: %Date{} = on, taken_at: at, uuid: uuid}) do
    time = if at, do: DateTime.to_iso8601(at), else: ""
    Base.url_encode64("#{on}|#{time}|#{uuid}", padding: false)
  end

  @doc "The condition of the files after a `cursor/1`, or `:error` when it is not one."
  @spec after_cursor(term()) :: {:ok, Ecto.Query.dynamic_expr()} | :error
  def after_cursor(cursor) when is_binary(cursor) do
    with {:ok, text} <- Base.url_decode64(cursor, padding: false),
         [on, at, uuid] <- String.split(text, "|"),
         {:ok, on} <- Date.from_iso8601(on),
         {:ok, at} <- cursor_time(at),
         {:ok, uuid} <- Ecto.UUID.cast(uuid) do
      {:ok, after_condition(%{taken_on: on, taken_at: at, uuid: uuid})}
    else
      _ -> :error
    end
  end

  def after_cursor(_cursor), do: :error

  defp cursor_time(""), do: {:ok, nil}

  defp cursor_time(text) do
    case DateTime.from_iso8601(text) do
      {:ok, at, _offset} -> {:ok, at}
      {:error, _reason} -> :error
    end
  end

  # A file without a time sorts after those that have one, as in `before_condition/1`.
  defp after_condition(%{taken_at: nil} = file) do
    dynamic(
      [f],
      f.taken_on > ^file.taken_on or
        (f.taken_on == ^file.taken_on and is_nil(f.taken_at) and f.uuid > ^file.uuid)
    )
  end

  defp after_condition(file) do
    dynamic(
      [f],
      f.taken_on > ^file.taken_on or
        (f.taken_on == ^file.taken_on and
           (is_nil(f.taken_at) or f.taken_at > ^file.taken_at or
              (f.taken_at == ^file.taken_at and f.uuid > ^file.uuid)))
    )
  end

  @doc """
  Where a photo is in the timeline: how many photos of the library come before it, in
  the order the timeline shows them (by day, then `taken_at`, then uuid). The browser
  opens the swipe viewer at that position, so an address that names a photo can open on it.

  `{:error, :not_found}` for a file that is not in the library or that `auth` may not read.
  """
  @spec position(scope(), String.t(), Scope.t() | nil) ::
          {:ok, non_neg_integer()} | {:error, error()}
  def position({:library, library_uuid}, uuid, auth) when is_binary(library_uuid) do
    with :ok <- capture_dates(),
         :ok <- known_library(library_uuid),
         :ok <- reader(auth, library_uuid),
         {:ok, uuid} <- Ecto.UUID.cast(uuid),
         %StorageFile{} = file <-
           library_uuid |> visible(auth) |> where([f], f.uuid == ^uuid) |> repo().one(),
         true <- Libraries.can?(auth, file, :read) do
      before =
        library_uuid
        |> visible(auth)
        |> where(^before_condition(file))
        |> repo().aggregate(:count)

      {:ok, before}
    else
      {:error, _} = error -> error
      _ -> {:error, :not_found}
    end
  end

  def position(_scope, _uuid, _auth), do: {:error, :unauthorized}

  # The files that sort before `file`: an earlier day, or the same day and an earlier
  # `taken_at`, or the same `taken_at` and an earlier uuid. A file without a time
  # sorts after those that have one (Postgres puts NULLs last in ascending order).
  defp before_condition(%StorageFile{taken_at: nil} = file) do
    dynamic(
      [f],
      f.taken_on < ^file.taken_on or
        (f.taken_on == ^file.taken_on and
           (not is_nil(f.taken_at) or (is_nil(f.taken_at) and f.uuid < ^file.uuid)))
    )
  end

  defp before_condition(%StorageFile{} = file) do
    dynamic(
      [f],
      f.taken_on < ^file.taken_on or
        (f.taken_on == ^file.taken_on and
           (f.taken_at < ^file.taken_at or (f.taken_at == ^file.taken_at and f.uuid < ^file.uuid)))
    )
  end

  @doc "Most files `slides/6` returns at once."
  @spec slide_limit() :: pos_integer()
  def slide_limit, do: @slide_limit

  @doc "Read-authorized data for PhoenixKit's existing canvas viewer."
  def viewer_file({:library, library_uuid}, uuid, auth) when is_binary(library_uuid) do
    with {:ok, uuid} <- Ecto.UUID.cast(uuid),
         :ok <- reader(auth, library_uuid),
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

  defp restrict(query, library_uuid, %Scope{user: nil}), do: restrict(query, library_uuid, nil)

  defp restrict(query, library_uuid, %Scope{} = scope) do
    cond do
      Scope.system_role?(scope) ->
        query

      readable_library?(scope, library_uuid) ->
        query

      match?(%{kind: "user"}, Libraries.get_library(library_uuid)) ->
        where(query, [f], false)

      uuid = Scope.user_uuid(scope) ->
        where(query, [f], f.user_uuid == ^uuid)

      true ->
        where(query, [f], false)
    end
  end

  defp restrict(query, library_uuid, nil) do
    if Libraries.audience_allows?(nil, Libraries.get_library(library_uuid)),
      do: query,
      else: where(query, [f], false)
  end

  defp restrict(query, _library_uuid, _scope), do: where(query, [f], false)

  # A member of a user library may read every file in it. A system library
  # (Media included) grants read only to the uploader or an Owner/Admin,
  # which `Libraries.can?/3` already encodes — Owner/Admin is handled above.
  defp readable_library?(scope, library_uuid) do
    case Libraries.get_library(library_uuid) do
      %{kind: "user", trashed_at: nil} = library ->
        Libraries.can_read_library?(scope, library)

      _ ->
        false
    end
  end

  defp completed_instances do
    from(i in FileInstance, where: i.processing_status == "completed")
  end

  # A window is up to 500 files of one library, and what a URL needs is mostly the same for all
  # of them: who may read is a matter of the library and the uploader, which sizes fit is a matter
  # of the library's set and the file's kind and shape, and a library is private or it is not.
  # Asked per file, as `Storage.authorized_url/4` and `variant_for/2` would, that is over twenty
  # queries a file.
  defp to_items(files, library_uuid, auth) do
    private? = Libraries.private_file?(%{library_uuid: library_uuid})

    readable =
      files
      |> Enum.map(& &1.user_uuid)
      |> Enum.uniq()
      |> Map.new(fn uploader ->
        {uploader,
         Libraries.can?(auth, %{library_uuid: library_uuid, user_uuid: uploader}, :read)}
      end)

    {items, _sizes} =
      files
      |> Enum.filter(&readable[&1.user_uuid])
      |> Enum.map_reduce(%{}, fn file, sizes ->
        key = {file.file_type, Shape.classify(file)}
        sizes = Map.put_new_lazy(sizes, key, fn -> size_names(file) end)
        {to_item(file, sizes[key], private?), sizes}
      end)

    items
  end

  defp size_names(file) do
    %{
      thumb: Storage.variant_for(file, min_width: @thumb_min_width, aspect: :crop),
      fit: Storage.variant_for(file, min_width: @fit_min_width, aspect: :preserve),
      preview: Storage.variant_for(file, min_width: @preview_min_width, aspect: :preserve),
      large: Storage.variant_for(file, min_width: @large_min_width, aspect: :preserve)
    }
  end

  defp to_item(%StorageFile{} = file, sizes, private?) do
    %{
      id: file.uuid,
      code: file.short_code,
      taken_at: file.taken_at,
      w: file.width,
      h: file.height,
      ar: file.width * 1.0 / file.height,
      thumb: signed_url(file, sizes.thumb, private?),
      # The styles that show whole photos: a small picture of the right shape, and a big one
      # for tiles that fill the page. Only what has been made: the file may be new.
      fit: made_url(file, sizes.fit, private?),
      preview: signed_url(file, sizes.preview, private?),
      large: made_url(file, sizes.large, private?),
      kind: if(file.file_type == "video", do: :video, else: :image),
      name: file.original_file_name || file.file_name,
      size: file.size,
      duration: file.duration
    }
  end

  # The caller has checked the reader (`to_items/3`).
  defp signed_url(_file, "original", _private?), do: nil

  defp signed_url(%StorageFile{instances: instances} = file, name, private?) do
    instance = Enum.find(instances || [], &(&1.variant_name == name))
    url_opts = if instance, do: [version: instance], else: []
    URLSigner.signed_url(to_string(file.uuid), name, [private: private?] ++ url_opts)
  end

  defp made_url(%StorageFile{instances: instances} = file, name, private?) do
    if Enum.any?(instances || [], &(&1.variant_name == name and name != "original")) do
      signed_url(file, name, private?)
    end
  end

  @web_images ~w(image/jpeg image/png image/webp image/gif image/avif)

  defp to_slide(%StorageFile{file_type: "video"} = file, auth, want) do
    {poster, poster_instance} =
      case pick(auth, file, min_width: want, output: :image) do
        {url, instance} -> {url, instance}
        nil -> {nil, nil}
      end

    rendition =
      case pick(auth, file, min_width: want, output: :video) do
        {url, _instance} -> [%{url: url, type: "video/mp4", role: :rendition}]
        nil -> []
      end

    {w, h} = dimensions(poster_instance, file)

    %{
      id: file.uuid,
      code: file.short_code,
      kind: :video,
      w: w,
      h: h,
      poster: poster,
      sources: rendition ++ original_source(auth, file)
    }
  end

  defp to_slide(%StorageFile{} = file, auth, want) do
    {src, instance} =
      case pick(auth, file, min_width: want, aspect: :preserve) do
        {url, instance} -> {url, instance}
        nil -> {original_image_url(auth, file), nil}
      end

    {w, h} = dimensions(instance, file)

    %{
      id: file.uuid,
      code: file.short_code,
      kind: :image,
      w: w,
      h: h,
      src: src,
      preview: variant_url(auth, file, min_width: @thumb_min_width, aspect: :preserve)
    }
  end

  defp original_source(auth, file) do
    case original_url(auth, file) do
      nil -> []
      url -> [%{url: url, type: file.mime_type || "video/mp4", role: :original}]
    end
  end

  # A browser can show only some originals (not a HEIC), and the viewer's
  # picture is a rendition whenever the set has one.
  defp original_image_url(auth, file) do
    if file.mime_type in @web_images, do: original_url(auth, file)
  end

  defp original_url(auth, %StorageFile{instances: instances} = file) do
    instance = Enum.find(instances || [], &(&1.variant_name == "original"))
    url_opts = if instance, do: [version: instance], else: []
    Storage.authorized_url(auth, file, "original", url_opts)
  end

  defp dimensions(%{width: w, height: h}, _file)
       when is_integer(w) and is_integer(h) and w > 0 and h > 0,
       do: {w, h}

  defp dimensions(_instance, file), do: {file.width, file.height}

  # The URL and the stored instance of the size `variant_for/2` picks, or nil
  # when the set has none (`"original"`) or the file has not made it yet: a
  # slide offers only what can be fetched.
  defp pick(auth, %StorageFile{instances: instances} = file, opts) do
    with name when is_binary(name) and name != "original" <- Storage.variant_for(file, opts),
         %{} = instance <- Enum.find(instances || [], &(&1.variant_name == name)),
         url when is_binary(url) <- Storage.authorized_url(auth, file, name, version: instance) do
      {url, instance}
    else
      _ -> nil
    end
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

  defp reader(scope, library_uuid) do
    case Libraries.get_library(library_uuid) do
      %{kind: "user"} = library ->
        if Libraries.can_read_library?(scope, library),
          do: :ok,
          else: {:error, :unauthorized}

      _ ->
        if match?(%Scope{}, scope) and (Scope.user_uuid(scope) || Scope.system_role?(scope)),
          do: :ok,
          else: {:error, :unauthorized}
    end
  end

  defp to_float(%Decimal{} = decimal), do: Decimal.to_float(decimal)
  defp to_float(number) when is_integer(number), do: number * 1.0
  defp to_float(number) when is_float(number), do: number
  defp to_float(nil), do: 0.0

  defp repo, do: RepoHelper.repo()
end
