defmodule PhoenixKitPhotos.Chapter do
  @moduledoc """
  A stretch of a library's time with a name: a trip, a move, a new job
  (`phoenix_kit_photo_chapters`, `PhoenixKitPhotos.Migrations` V2). `PhoenixKitPhotos.Chapters`
  is the way in; the timeline shows a chapter as a banner where it starts.

  `ends_on` is nil for a chapter without an end (yet): "Moved to Tallinn", or a trip still
  going. `parent_uuid` makes it a **sub-chapter** of another chapter of the same library, one
  level deep, inside that chapter's dates. `color` is one of `colors/0`: a name the
  timeline's CSS knows, never a value that reaches a stylesheet.

  `title` and `description` are in the site's main language; `translations` holds them in
  its other languages (V3), `%{"ru" => %{"title" => …, "description" => …}}`. `title/2`
  and `description/2` read a language, falling back to the main one.
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
    field :translations, :map, default: %{}

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
        :parent_uuid,
        :translations
      ],
      empty_values: [""]
    )
    |> update_change(:title, &squish/1)
    |> update_change(:emoji, &String.trim/1)
    |> update_change(:description, &String.trim/1)
    |> update_change(:translations, &clean_translations/1)
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

  # Only text, trimmed and within the limits; a language with nothing written is left out
  # (it falls back to the main language).
  defp clean_translations(translations) when is_map(translations) do
    for {lang, %{} = text} <- translations,
        is_binary(lang) and Regex.match?(~r/\A[A-Za-z]{2,3}([-_][A-Za-z0-9]{2,8})?\z/, lang),
        text = clean_text(text),
        text != %{},
        into: %{},
        do: {lang, text}
  end

  defp clean_translations(_other), do: %{}

  defp clean_text(text) do
    [
      {"title", text["title"] |> string() |> squish() |> String.slice(0, @max_title)},
      {"description",
       text["description"] |> string() |> String.trim() |> String.slice(0, @max_description)}
    ]
    |> Enum.reject(fn {_key, value} -> value == "" end)
    |> Map.new()
  end

  defp string(value) when is_binary(value), do: value
  defp string(_value), do: ""

  @doc ~s[The title in `lang` (a code like `"ru"` or `"et-EE"`), else the main language's.]
  @spec title(t(), String.t() | nil) :: String.t()
  def title(%__MODULE__{} = chapter, lang),
    do: translated(chapter, lang, "title") || chapter.title

  @doc "The description in `lang`, else the main language's (nil when there is none)."
  @spec description(t(), String.t() | nil) :: String.t() | nil
  def description(%__MODULE__{} = chapter, lang),
    do: translated(chapter, lang, "description") || chapter.description

  defp translated(%{translations: %{} = translations}, lang, key) when is_binary(lang) do
    base = lang_base(lang)

    text =
      translations[lang] ||
        Enum.find_value(translations, fn {code, text} -> if lang_base(code) == base, do: text end)

    case text do
      %{^key => value} when is_binary(value) and value != "" -> value
      _ -> nil
    end
  end

  defp translated(_chapter, _lang, _key), do: nil

  defp lang_base(code), do: code |> String.split(["-", "_"]) |> hd() |> String.downcase()

  defp squish(text) when is_binary(text), do: text |> String.split() |> Enum.join(" ")
  defp squish(other), do: other

  @doc "Whether `date` falls in the chapter (a chapter without an end holds its start day only)."
  @spec covers?(t(), Date.t()) :: boolean()
  def covers?(%__MODULE__{starts_on: starts, ends_on: ends}, %Date{} = date) do
    Date.compare(date, starts) != :lt and Date.compare(date, ends || starts) != :gt
  end
end
