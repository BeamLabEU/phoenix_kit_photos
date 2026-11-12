defmodule PhoenixKitPhotos.Fetches.Meta do
  @moduledoc """
  A title, an author and a date out of what a tool says about a post, a photo or a
  video. Every site names these differently (gallery-dl passes each site's own fields
  on: Flickr's `owner.username`, Bluesky's `author.displayName`, Wikimedia's `user`),
  so each is the first of several usual places that holds something.
  """

  @title_length 200
  @author_length 120

  @doc "The title, or the first line of the description or text, or nil."
  @spec title(map()) :: String.t() | nil
  def title(meta) when is_map(meta) do
    ["title", "fulltitle", "description", "content", "text", "caption"]
    |> Enum.find_value(fn key -> text(meta[key]) end)
    |> first_line()
    |> cut(@title_length)
  end

  def title(_meta), do: nil

  @doc "Who posted it, or nil."
  @spec author(map()) :: String.t() | nil
  def author(meta) when is_map(meta) do
    ["uploader", "channel", "creator", "author", "user", "owner", "artist", "username", "blog"]
    |> Enum.find_value(fn key -> name(meta[key]) end)
    |> cut(@author_length)
  end

  def author(_meta), do: nil

  @doc """
  When it was posted, as a `NaiveDateTime` (UTC), or nil: yt-dlp's `timestamp`,
  `release_timestamp` or `upload_date` (`20050424`), or gallery-dl's `date`
  (`2010-03-14 17:20:20`).
  """
  @spec posted_at(map()) :: NaiveDateTime.t() | nil
  def posted_at(meta) when is_map(meta) do
    unix(meta["timestamp"]) || unix(meta["release_timestamp"]) ||
      ymd(meta["upload_date"]) || date_time(meta["date"])
  end

  def posted_at(_meta), do: nil

  defp text(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      text -> text
    end
  end

  defp text(_value), do: nil

  defp name(value) when is_binary(value), do: text(value)

  defp name(%{} = value) do
    Enum.find_value(
      [
        "displayName",
        "display_name",
        "name",
        "fullname",
        "nick",
        "username",
        "handle",
        "screen_name"
      ],
      &text(value[&1])
    )
  end

  defp name(_value), do: nil

  defp first_line(nil), do: nil
  defp first_line(text), do: text |> String.split(~r/\r?\n/, parts: 2) |> hd() |> String.trim()

  defp cut(nil, _max), do: nil
  defp cut("", _max), do: nil

  defp cut(text, max) do
    if String.length(text) > max,
      do: String.slice(text, 0, max - 1) <> "…",
      else: text
  end

  defp unix(seconds) when is_integer(seconds) and seconds > 0 do
    case DateTime.from_unix(seconds) do
      {:ok, dt} -> dt |> DateTime.to_naive() |> NaiveDateTime.truncate(:second)
      _ -> nil
    end
  end

  defp unix(seconds) when is_float(seconds), do: unix(trunc(seconds))
  defp unix(_seconds), do: nil

  defp ymd(<<y::binary-size(4), m::binary-size(2), d::binary-size(2)>>) do
    with {year, ""} <- Integer.parse(y),
         {month, ""} <- Integer.parse(m),
         {day, ""} <- Integer.parse(d),
         {:ok, date} <- Date.new(year, month, day) do
      NaiveDateTime.new!(date, ~T[00:00:00])
    else
      _ -> nil
    end
  end

  defp ymd(_value), do: nil

  defp date_time(value) when is_binary(value) do
    case NaiveDateTime.from_iso8601(String.replace(value, " ", "T")) do
      {:ok, dt} -> NaiveDateTime.truncate(dt, :second)
      _ -> nil
    end
  end

  defp date_time(_value), do: nil
end
