defmodule PhoenixKitPhotos.Chapter do
  @moduledoc """
  A stretch of a library's time with a name: a trip, a move, a new job
  (`phoenix_kit_photo_chapters`, `PhoenixKitPhotos.Migrations` V2). `PhoenixKitPhotos.Chapters`
  is the way in; the timeline shows a chapter as a banner where it starts.

  `ends_on` is nil for a chapter without an end (yet): "Moved to Tallinn", or a trip still
  going. `parent_uuid` makes it a **sub-chapter** of another chapter of the same library, one
  level deep, inside that chapter's dates. `color` is one of `colors/0`: a name the
  timeline's CSS knows, never a value that reaches a stylesheet.
  """

  use Ecto.Schema
  use PhoenixKit.SchemaPrefix

  import Ecto.Changeset

  @primary_key {:uuid, UUIDv7, autogenerate: true}
  @foreign_key_type UUIDv7

  @colors ~w(sky rose amber emerald violet slate)
  @max_title 120
  @max_emoji 16
  @max_description 2000

  schema "phoenix_kit_photo_chapters" do
    field :library_uuid, UUIDv7
    field :parent_uuid, UUIDv7
    field :title, :string
    field :emoji, :string
    field :description, :string
    field :color, :string
    field :starts_on, :date
    field :ends_on, :date
    field :cover_file_uuid, UUIDv7
    field :created_by_uuid, UUIDv7

    timestamps(type: :naive_datetime)
  end

  @type t :: %__MODULE__{}

  @doc "The colours a chapter may have, the first being the default."
  @spec colors() :: [String.t()]
  def colors, do: @colors

  def max_title, do: @max_title
  def max_emoji, do: @max_emoji
  def max_description, do: @max_description

  @doc "What a person may set: the text, the colour, the dates, the cover and the parent."
  def changeset(chapter, attrs) do
    chapter
    |> cast(
      attrs,
      [
        :title,
        :emoji,
        :description,
        :color,
        :starts_on,
        :ends_on,
        :cover_file_uuid,
        :parent_uuid
      ],
      empty_values: [""]
    )
    |> update_change(:title, &squish/1)
    |> update_change(:emoji, &String.trim/1)
    |> update_change(:description, &String.trim/1)
    |> validate_required([:title, :starts_on], message: "can't be blank")
    |> validate_length(:title, min: 1, max: @max_title)
    |> validate_length(:emoji, max: @max_emoji, count: :bytes)
    |> validate_length(:description, max: @max_description)
    |> validate_inclusion(:color, @colors)
    |> validate_dates()
  end

  defp validate_dates(changeset) do
    starts = get_field(changeset, :starts_on)
    ends = get_field(changeset, :ends_on)

    if starts && ends && Date.compare(ends, starts) == :lt,
      do: add_error(changeset, :ends_on, "is before the start"),
      else: changeset
  end

  defp squish(text) when is_binary(text), do: text |> String.split() |> Enum.join(" ")
  defp squish(other), do: other

  @doc "Whether `date` falls in the chapter (a chapter without an end holds its start day only)."
  @spec covers?(t(), Date.t()) :: boolean()
  def covers?(%__MODULE__{starts_on: starts, ends_on: ends}, %Date{} = date) do
    Date.compare(date, starts) != :lt and Date.compare(date, ends || starts) != :gt
  end
end
