defmodule PhoenixKitMediaTimeline.Timeline do
  @moduledoc """
  The server side of the timeline: a monthly index and per-day windows.

  ## The two shapes

  The index is a cheap aggregation — a few hundred month buckets for a library
  of any size — and is what the scrubber track is drawn from:

      %{total: 184_203, sections: [%{id: "2018-07", count: 412, sum_aspect: 548.2, days: 19}]}

  A window is **one day**, capped at `@window_limit` items. Windows are days
  rather than months because a holiday month of 20k items is roughly 5MB over
  the LiveView socket, while a day is tens to a few hundred tiles.

  ## Not implemented yet, deliberately

  Every function here needs capture-date columns that do not exist in
  PhoenixKit 2.32.x–2.34.x:

  | column | role |
  |---|---|
  | `taken_at` | UTC instant — ordering and "jump to this moment" |
  | `taken_on` | local date — month/day buckets and headers |
  | `taken_at_offset` | UTC offset in seconds, so the viewer can show local time |
  | `taken_at_source` | `:exif` / `:filename` / `:inserted_at` / `:manual` |

  They belong on `phoenix_kit_files` in core (Stage 0, an upstream PR), not in
  this package's migrations. Bucketing on `inserted_at` instead would be worse
  than an error: a library would look plausible and be wrong.
  """

  @window_limit 500

  @typedoc "A month bucket: `\"2018-07\"`."
  @type section_id :: String.t()

  @typedoc "A day window: `\"2018-07-14\"`."
  @type window_id :: String.t()

  @type scope :: {:user, String.t()}

  @type section :: %{
          id: section_id(),
          count: non_neg_integer(),
          sum_aspect: float(),
          days: non_neg_integer()
        }

  @type index :: %{total: non_neg_integer(), sections: [section()]}

  @type item :: %{
          id: String.t(),
          taken_at: DateTime.t(),
          w: pos_integer(),
          h: pos_integer(),
          ar: float(),
          thumb: String.t(),
          preview: String.t(),
          kind: :image | :video
        }

  @type window :: %{section: window_id(), items: [item()]}

  @doc "Maximum items returned in a single window before it must be subdivided."
  @spec window_limit() :: pos_integer()
  def window_limit, do: @window_limit

  @doc """
  The predicates every timeline query must carry, on `phoenix_kit_files`.

  Returned as a keyword list so the query builder and the migration's partial
  index are written from one definition and cannot drift apart.

  `status == "active"` keeps processing and failed rows out — they have no
  variants and would render as permanently grey tiles. The dimension predicate
  keeps `ar` from blowing up the layout and incidentally excludes the
  historical rows where a `.mov` was stored as `file_type: "image"`.

  Note what is absent: `edit_state` in `pending`/`failed` occupies the same
  uuid and belongs in the grid, because `FileController` already serves a
  placeholder for it.
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
  Monthly index for a scope.

  Live aggregation, not a materialized projection: at 100k rows a `GROUP BY
  taken_on` against the partial index is cheap, while a projection incremented
  on ingest/trash/restore is where the subtle bugs live. Materialize only after
  measuring, and debounce per owner if you do.
  """
  @spec index(scope()) :: {:ok, index()} | {:error, :capture_date_unavailable}
  def index({:user, _user_uuid}), do: {:error, :capture_date_unavailable}

  @doc """
  One day of items for a scope, at most `window_limit/0`.

  The caller must authorize the scope. Signed thumbnail URLs do not.
  """
  @spec window(scope(), window_id()) ::
          {:ok, window()} | {:error, :capture_date_unavailable}
  def window({:user, _user_uuid}, _day), do: {:error, :capture_date_unavailable}
end
