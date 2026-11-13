defmodule PhoenixKitPhotos.Places do
  @moduledoc """
  Names of places: finding a place by what a person types (`search/2`, for putting a
  photo on the map), and naming the place a photo was taken (`name/4`).

  Both ask a geocoder with the Nominatim API: OpenStreetMap's public server unless the
  host names another. A busy site needs its own server or a paid one: the public one
  allows **one request a second** in all and asks to be told who is asking. So:

      config :phoenix_kit_photos, PhoenixKitPhotos.Places,
        enabled: true,
        user_agent: "MySite (https://example.com)",
        search_url: "https://nominatim.openstreetmap.org/search",
        reverse_url: "https://nominatim.openstreetmap.org/reverse",
        min_interval_ms: 1_100

  Off unless `enabled: true`: a page then offers no search and shows no place names, and
  a photo's place is still shown on the map. Requests are spaced by `min_interval_ms`
  across the whole node, and one that would wait more than a few seconds is not made
  (`{:error, :busy}`). Answers are kept for a day.

  What leaves the site: the words typed into the search, and for a name a position
  rounded to about 100 metres, never who asked. The server makes the requests, so the
  person's address is not sent either.

  The map's tiles are the browser's to fetch, from `tiles/0`.
  """

  use GenServer

  require Logger

  @table :phoenix_kit_photos_places
  @ttl_ms :timer.hours(24)
  @max_wait_ms 3_000
  @max_query 200

  @default_search "https://nominatim.openstreetmap.org/search"
  @default_reverse "https://nominatim.openstreetmap.org/reverse"
  @default_tiles "https://tile.openstreetmap.org/{z}/{x}/{y}.png"
  @default_attribution "© OpenStreetMap"

  @type place :: %{name: String.t(), latitude: float(), longitude: float()}

  # ---------------------------------------------------------------------------
  # Asking

  @doc "Whether places can be searched for and named."
  @spec enabled?() :: boolean()
  def enabled?, do: config()[:enabled] == true and running?()

  @doc """
  Places matching `query`, best first (at most five), named in `lang` where the
  geocoder knows the name in it. `{:error, reason}` when it cannot be asked.
  """
  @spec search(String.t(), String.t() | nil) :: {:ok, [place()]} | {:error, term()}
  def search(query, lang) when is_binary(query) do
    query = query |> String.trim() |> String.slice(0, @max_query)

    cond do
      query == "" -> {:ok, []}
      not enabled?() -> {:error, :disabled}
      true -> cached({:search, String.downcase(query), lang}, fn -> do_search(query, lang) end)
    end
  end

  def search(_query, _lang), do: {:ok, []}

  @doc """
  The name of the place at `{latitude, longitude}` in `lang`: a town or a district for
  `:area` (`detail`), a street and town for `:exact`. `nil` when there is none, the
  geocoder is off or busy.
  """
  @spec name(number(), number(), String.t() | nil, :exact | :area) :: String.t() | nil
  def name(lat, lon, lang, detail \\ :exact)

  def name(lat, lon, lang, detail) when is_number(lat) and is_number(lon) do
    if enabled?(),
      do: ask_name(Float.round(lat * 1.0, 3), Float.round(lon * 1.0, 3), lang, detail)
  end

  def name(_lat, _lon, _lang, _detail), do: nil

  defp ask_name(lat, lon, lang, detail) do
    case cached({:name, lat, lon, lang, detail}, fn -> do_name(lat, lon, lang, detail) end) do
      {:ok, name} -> name
      _ -> nil
    end
  end

  @doc """
  `name/4` without asking the geocoder: `{:ok, name}` (nil for a place with none) when
  the answer is known, `:unknown` when `name/4` would have to ask, `:off` when it would
  not ask at all. For a page that shows what it has at once and asks in the background.
  """
  @spec peek(number(), number(), String.t() | nil, :exact | :area) ::
          {:ok, String.t() | nil} | :unknown | :off
  def peek(lat, lon, lang, detail \\ :exact)

  def peek(lat, lon, lang, detail) when is_number(lat) and is_number(lon) do
    if enabled?() do
      key = {:name, Float.round(lat * 1.0, 3), Float.round(lon * 1.0, 3), lang, detail}
      now = System.monotonic_time(:millisecond)

      case lookup(key) do
        {:ok, {:ok, name}, expires} when expires > now -> {:ok, name}
        {:ok, _failed, expires} when expires > now -> {:ok, nil}
        _ -> :unknown
      end
    else
      :off
    end
  end

  def peek(_lat, _lon, _lang, _detail), do: :off

  @doc """
  Where the browser draws the map from: `%{url: template, attribution: text}`.
  `config :phoenix_kit_photos, :map_tiles, url: …, attribution: …`.
  """
  @spec tiles() :: %{url: String.t(), attribution: String.t()}
  def tiles do
    config = Application.get_env(:phoenix_kit_photos, :map_tiles, [])

    %{
      url: config[:url] || @default_tiles,
      attribution: config[:attribution] || @default_attribution
    }
  end

  # ---------------------------------------------------------------------------
  # The geocoder

  defp do_search(query, lang) do
    params = [q: query, format: "jsonv2", limit: 5, addressdetails: 0]

    with {:ok, body} <- get(config()[:search_url] || @default_search, params, lang),
         list when is_list(list) <- body do
      {:ok, list |> Enum.map(&place/1) |> Enum.reject(&is_nil/1)}
    else
      {:error, _} = error -> error
      _ -> {:error, :bad_answer}
    end
  end

  defp do_name(lat, lon, lang, detail) do
    # Nominatim's zoom: 10 is a town, 16 a street.
    zoom = if detail == :area, do: 10, else: 16
    params = [lat: lat, lon: lon, format: "jsonv2", zoom: zoom, addressdetails: 1]

    case get(config()[:reverse_url] || @default_reverse, params, lang) do
      {:ok, %{} = body} -> {:ok, short_name(body, detail)}
      {:error, _} = error -> error
      _ -> {:error, :bad_answer}
    end
  end

  defp place(%{"display_name" => name, "lat" => lat, "lon" => lon}) do
    with {lat, _} <- Float.parse(to_string(lat)),
         {lon, _} <- Float.parse(to_string(lon)) do
      %{name: name, latitude: lat, longitude: lon}
    else
      _ -> nil
    end
  end

  defp place(_other), do: nil

  # "Raekoja plats, Vanalinn, Tallinn, Harju maakond, 10146, Eesti" is too much for a
  # line under a photo: the street (for an exact place), the district or town, the country.
  @doc false
  def short_name(%{"address" => %{} = address} = body, detail) do
    street =
      if detail == :exact,
        do: first(address, ~w(road pedestrian square park attraction building)),
        else: nil

    town =
      first(address, ~w(city town village hamlet municipality suburb county state))

    parts =
      [street, town, address["country"]]
      |> Enum.reject(&(&1 in [nil, ""]))
      |> Enum.uniq()

    case parts do
      [] -> body["display_name"]
      parts -> Enum.join(parts, ", ")
    end
  end

  def short_name(%{"display_name" => name}, _detail) when is_binary(name), do: name
  def short_name(_body, _detail), do: nil

  defp first(address, keys), do: Enum.find_value(keys, &address[&1])

  defp get(url, params, lang) do
    with :ok <- take_turn() do
      headers =
        [{"user-agent", config()[:user_agent] || "PhoenixKitPhotos"}] ++
          if(is_binary(lang), do: [{"accept-language", lang}], else: [])

      case Req.get(url,
             params: params,
             headers: headers,
             receive_timeout: 6_000,
             connect_options: [timeout: 4_000],
             retry: false
           ) do
        {:ok, %{status: 200, body: body}} ->
          {:ok, body}

        {:ok, %{status: status}} ->
          Logger.warning("Places: the geocoder answered #{status}")
          {:error, {:status, status}}

        {:error, reason} ->
          Logger.warning("Places: the geocoder could not be reached: #{inspect(reason)}")
          {:error, :unreachable}
      end
    end
  end

  defp config, do: Application.get_env(:phoenix_kit_photos, __MODULE__, [])

  # ---------------------------------------------------------------------------
  # The cache and the turns

  defp cached(key, fun) do
    now = System.monotonic_time(:millisecond)

    case lookup(key) do
      {:ok, value, expires} when expires > now ->
        value

      _ ->
        value = fun.()
        # A failure is kept briefly, so a geocoder that is down is not asked on every page.
        ttl = if match?({:ok, _}, value), do: @ttl_ms, else: :timer.minutes(1)
        store(key, value, now + ttl)
        value
    end
  end

  defp lookup(key) do
    case :ets.lookup(@table, key) do
      [{^key, value, expires}] -> {:ok, value, expires}
      _ -> :miss
    end
  rescue
    ArgumentError -> :miss
  end

  defp store(key, value, expires) do
    :ets.insert(@table, {key, value, expires})
  rescue
    ArgumentError -> :ok
  end

  # One request at a time across the node, spaced by `min_interval_ms`.
  defp take_turn do
    case GenServer.call(__MODULE__, :turn) do
      {:wait, ms} when ms <= @max_wait_ms ->
        if ms > 0, do: Process.sleep(ms)
        :ok

      _ ->
        {:error, :busy}
    end
  catch
    :exit, _ -> {:error, :busy}
  end

  defp running?, do: is_pid(Process.whereis(__MODULE__))

  # ---------------------------------------------------------------------------
  # GenServer: owns the cache table and hands out turns.

  @doc false
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    :timer.send_interval(:timer.minutes(30), :sweep)
    {:ok, %{next: 0}}
  end

  @impl true
  def handle_call(:turn, _from, %{next: next} = state) do
    now = System.monotonic_time(:millisecond)
    at = max(now, next)
    wait = at - now

    if wait > @max_wait_ms do
      {:reply, :busy, state}
    else
      interval = config()[:min_interval_ms] || 1_100
      {:reply, {:wait, wait}, %{state | next: at + interval}}
    end
  end

  @impl true
  def handle_info(:sweep, state) do
    now = System.monotonic_time(:millisecond)
    :ets.select_delete(@table, [{{:_, :_, :"$1"}, [{:<, :"$1", now}], [true]}])
    {:noreply, state}
  end
end
