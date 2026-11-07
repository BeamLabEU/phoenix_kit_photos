defmodule PhoenixKitPhotos.Zip do
  @moduledoc """
  A ZIP archive written front to back, for answering a download while the files are still being
  read: nothing is ever seeked back to, so it goes straight into a chunked response.

  Files are stored, not compressed: photos and videos are compressed already, and deflating them
  costs a lot of CPU to save almost nothing. ZIP64 records appear only when a size or an offset
  needs them, so an ordinary archive opens in everything, and one of 40 GB still works.

  Each file is measured before it is written (`add/5`), which is why the headers can carry the
  real sizes and need no data descriptors. That is also what makes a file that cannot be read
  harmless: `{:error, {:read, reason}}` means nothing of it was written and the archive can go
  on. `{:error, {:write, reason}}` means it cannot: stop, and do not `finish/1`, so what the
  reader has is plainly broken rather than quietly short.
  """

  import Bitwise

  @chunk 1_048_576
  @limit 0xFFFFFFFF
  # Bit 11: names are UTF-8.
  @flags 0x0800
  @stored 0
  @version 45

  defstruct offset: 0, entries: []

  @type t :: %__MODULE__{offset: non_neg_integer(), entries: list()}

  @doc "An empty archive."
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc """
  Adds the file at `path` as `name`, sending the bytes through `write`, a function of iodata that
  answers `:ok` or `{:error, reason}`. `time` is the file's date, a `DateTime` or nil.
  """
  @spec add(t(), String.t(), Path.t(), DateTime.t() | nil, (iodata() -> :ok | {:error, term()})) ::
          {:ok, t()} | {:error, {:read | :write, term()}}
  def add(%__MODULE__{} = zip, name, path, time, write) do
    with {:ok, size, crc} <- measure(path),
         entry = %{name: name, size: size, crc: crc, offset: zip.offset, time: dos_time(time)},
         header = local_header(entry),
         :ok <- written(write.(header)),
         :ok <- send_file(path, write) do
      {:ok,
       %{
         zip
         | offset: zip.offset + IO.iodata_length(header) + size,
           entries: [entry | zip.entries]
       }}
    end
  end

  @doc "Adds a small text as a file, for a note about the archive itself."
  @spec add_text(t(), String.t(), iodata(), (iodata() -> :ok | {:error, term()})) ::
          {:ok, t()} | {:error, {:write, term()}}
  def add_text(%__MODULE__{} = zip, name, text, write) do
    text = IO.iodata_to_binary(text)
    size = byte_size(text)

    entry = %{
      name: name,
      size: size,
      crc: :erlang.crc32(text),
      offset: zip.offset,
      time: dos_time(nil)
    }

    header = local_header(entry)

    with :ok <- written(write.([header, text])) do
      {:ok,
       %{
         zip
         | offset: zip.offset + IO.iodata_length(header) + size,
           entries: [entry | zip.entries]
       }}
    end
  end

  defp written(:ok), do: :ok
  defp written({:error, reason}), do: {:error, {:write, reason}}

  defp measure(path) do
    with {:ok, %{size: size}} <- File.stat(path),
         {:ok, crc} <- crc(path) do
      {:ok, size, crc}
    else
      {:error, reason} -> {:error, {:read, reason}}
    end
  end

  @doc "The part of the archive that comes after the files."
  @spec finish(t()) :: iodata()
  def finish(%__MODULE__{offset: start, entries: entries}) do
    entries = Enum.reverse(entries)
    directory = Enum.map(entries, &central_header/1)
    size = IO.iodata_length(directory)
    count = length(entries)
    big? = start >= @limit or size >= @limit or count >= 0xFFFF

    [
      directory,
      if(big?, do: zip64_end(count, size, start), else: []),
      end_record(count, size, start)
    ]
  end

  defp crc(path) do
    {:ok, path |> File.stream!(@chunk) |> Enum.reduce(0, &:erlang.crc32(&2, &1))}
  rescue
    error in File.Error -> {:error, error.reason}
  end

  defp send_file(path, write) do
    path
    |> File.stream!(@chunk)
    |> Enum.reduce_while(:ok, fn chunk, :ok ->
      case write.(chunk) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, {:write, reason}}}
      end
    end)
  rescue
    # The header has gone out: this one cannot be left out any more.
    error in File.Error -> {:error, {:write, error.reason}}
  end

  defp local_header(%{name: name, size: size, crc: crc, time: {time, date}}) do
    big? = size >= @limit

    extra =
      if big?,
        do: <<0x0001::little-16, 16::little-16, size::little-64, size::little-64>>,
        else: <<>>

    stated = if big?, do: @limit, else: size

    [
      <<0x04034B50::little-32, @version::little-16, @flags::little-16, @stored::little-16,
        time::little-16, date::little-16, crc::little-32, stated::little-32, stated::little-32,
        byte_size(name)::little-16, byte_size(extra)::little-16>>,
      name,
      extra
    ]
  end

  defp central_header(%{name: name, size: size, crc: crc, offset: offset, time: {time, date}}) do
    big_size? = size >= @limit
    big_offset? = offset >= @limit

    fields =
      if(big_size?, do: <<size::little-64, size::little-64>>, else: <<>>) <>
        if big_offset?, do: <<offset::little-64>>, else: <<>>

    extra =
      if fields == <<>>,
        do: <<>>,
        else: <<0x0001::little-16, byte_size(fields)::little-16, fields::binary>>

    stated = if big_size?, do: @limit, else: size
    place = if big_offset?, do: @limit, else: offset

    [
      <<0x02014B50::little-32, @version::little-16, @version::little-16, @flags::little-16,
        @stored::little-16, time::little-16, date::little-16, crc::little-32, stated::little-32,
        stated::little-32, byte_size(name)::little-16, byte_size(extra)::little-16, 0::little-16,
        0::little-16, 0::little-16, 0::little-32, place::little-32>>,
      name,
      extra
    ]
  end

  defp zip64_end(count, size, start) do
    <<0x06064B50::little-32, 44::little-64, @version::little-16, @version::little-16,
      0::little-32, 0::little-32, count::little-64, count::little-64, size::little-64,
      start::little-64, 0x07064B50::little-32, 0::little-32, start + size::little-64,
      1::little-32>>
  end

  defp end_record(count, size, start) do
    <<0x06054B50::little-32, 0::little-16, 0::little-16, min(count, 0xFFFF)::little-16,
      min(count, 0xFFFF)::little-16, min(size, @limit)::little-32, min(start, @limit)::little-32,
      0::little-16>>
  end

  # ZIP keeps time as local fields from 1980 on, to two seconds.
  defp dos_time(%DateTime{year: year} = at) when year >= 1980 do
    time = at.hour <<< 11 ||| at.minute <<< 5 ||| div(at.second, 2)
    date = (year - 1980) <<< 9 ||| at.month <<< 5 ||| at.day
    {time, date}
  end

  defp dos_time(_other), do: {0, 1 <<< 5 ||| 1}
end
