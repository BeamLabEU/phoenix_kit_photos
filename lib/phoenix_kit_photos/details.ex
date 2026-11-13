defmodule PhoenixKitPhotos.Details do
  @moduledoc """
  What the swipe viewer's info panel (`PhoenixKitPhotos.Components.InfoPanel`) shows of
  one photo, and the changes it makes: the title and description in each of the site's
  languages, the date it was taken, where it was taken.

  `load/4` reads a photo for a person and decides, once, what they may see and do:

    * the **text** in the page's language, falling back to another language the photo
      has (and saying which), and for an editor what each language holds itself;
    * the **date**: its local time, its time zone when known, where it came from (the
      camera, the file's name, the upload, a person); in a stack, the stack's date, which
      moves the whole stack;
    * the **place**, as much of it as the library shows this person
      (`PhoenixKitPhotos.Sharing`): exact, an area, or nothing;
    * **comments**: `:write`, `:read` or `:none`.

  The changes check again, on the server, that the person may edit the photo
  (`Libraries.can?/3` with `:edit`) before writing anything; the panel's own idea of it
  is only what it offers.
  """

  use Gettext, backend: PhoenixKitPhotos.Gettext

  alias PhoenixKit.Modules.Languages.DialectMapper
  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Modules.Storage.File, as: StorageFile
  alias PhoenixKit.Modules.Storage.{FileDetails, Libraries, ManualDate, ManualLocation, Stacks}
  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKit.Utils.Multilang
  alias PhoenixKitPhotos.{Places, Sharing, Timeline}

  @type t :: map()

  # ---------------------------------------------------------------------------
  # Reading

  @doc """
  The panel's data for photo `file_uuid` of the timeline's `scope`, seen by `auth` in
  `locale` (the page's language). `{:error, :not_found}` when they may not read it.
  """
  @spec load(Timeline.scope(), String.t(), Scope.t() | nil, String.t() | nil) ::
          {:ok, t()} | {:error, :not_found}
  def load({:library, library_uuid} = scope, file_uuid, auth, locale) do
    with {:ok, file} <- Timeline.readable_file(scope, file_uuid, auth) do
      library = Libraries.get_library(library_uuid)
      audience = Sharing.audience(auth, library)
      editor? = is_struct(auth, Scope) and Libraries.can?(auth, file, :edit)
      primary = Multilang.primary_language()
      lang = FileDetails.content_language(locale, primary: primary)
      stack = stack(file, auth)

      {:ok,
       %{
         file: file,
         file_uuid: file.uuid,
         library: library,
         audience: audience,
         editor?: editor?,
         lang: lang,
         languages: languages(lang),
         text: shown_text(file, lang, primary),
         own: if(editor?, do: own_texts(file, lang, primary)),
         date: date(file, stack),
         stack: stack,
         place: place(file, library, audience, lang),
         comments: Sharing.comment_view(library, audience),
         facts: facts(file)
       }}
    end
  end

  # What the page shows: each field in the page's language, else in another the photo
  # has. `:from` is the language the title or description shown is really in, when it is
  # not the page's.
  defp shown_text(file, lang, primary) do
    shown = FileDetails.for_locale(file, lang, primary: primary)
    own = FileDetails.from_file(file, lang, primary: primary)

    from =
      cond do
        present?(own.title) or present?(own.description) -> nil
        present?(shown.title) or present?(shown.description) -> source_language(file, shown)
        true -> nil
      end

    %{
      title: blank_nil(shown.title),
      description: blank_nil(shown.description),
      alt: blank_nil(shown.alt),
      from: from && language_label(from)
    }
  end

  defp source_language(file, shown) do
    data = if is_map(file.data), do: file.data, else: %{}

    Enum.find_value(Enum.sort(data), fn
      {code, %{} = entry} ->
        if (present?(shown.title) and entry["title"] == shown.title) or
             (present?(shown.description) and entry["description"] == shown.description),
           do: code

      _ ->
        nil
    end)
  end

  # For an editor: what each language holds itself, the page's first.
  defp own_texts(file, lang, primary) do
    codes = [lang | Enum.reject(enabled_languages(), &(&1 == lang))]

    for code <- codes, into: %{} do
      details = FileDetails.from_file(file, code, primary: primary)

      {code,
       %{
         "title" => details.title || "",
         "description" => details.description || "",
         "alt" => details.alt || ""
       }}
    end
  end

  # The site's languages, the page's first: `[%{code, name, short}]`. One entry on a
  # site with one language.
  defp languages(lang) do
    tabs = Multilang.build_language_tabs()

    case tabs do
      [] ->
        [%{code: lang, name: language_label(lang), short: short(lang)}]

      tabs ->
        {mine, others} = Enum.split_with(tabs, &(&1.code == lang))

        Enum.map(mine ++ others, fn tab ->
          %{code: tab.code, name: tab.name, short: short(tab.code)}
        end)
    end
  end

  defp enabled_languages do
    case Multilang.enabled_languages() do
      [] -> [Multilang.primary_language()]
      list -> list
    end
  end

  defp short(code), do: code |> DialectMapper.extract_base() |> String.upcase()

  defp language_label(code) do
    Enum.find_value(Multilang.build_language_tabs(), short(code), fn tab ->
      if tab.code == code or
           DialectMapper.extract_base(tab.code) == DialectMapper.extract_base(code),
         do: tab.name
    end)
  end

  defp stack(%StorageFile{stack_uuid: nil}, _auth), do: nil

  defp stack(%StorageFile{stack_uuid: stack_uuid} = file, auth) do
    files = stack_uuid |> Stacks.files() |> Enum.filter(&is_nil(&1.trashed_at))

    case files do
      [_, _ | _] ->
        stack = Stacks.get(stack_uuid)

        %{
          uuid: stack_uuid,
          title: stack && stack.title,
          count: length(files),
          files: Enum.map(files, & &1.uuid),
          cover: hd(files),
          editable?:
            is_struct(auth, Scope) and Enum.all?(files, &Libraries.can?(auth, &1, :edit)),
          position: Enum.find_index(files, &(&1.uuid == file.uuid))
        }

      _ ->
        nil
    end
  end

  # The date shown, and the one a change starts from: a stack's is its cover's (the
  # timeline places a stack by its cover), a photo's its own.
  defp date(file, stack) do
    anchor = if stack, do: stack.cover, else: file
    local = ManualDate.local(anchor)

    %{
      local: local,
      dated?: not is_nil(anchor.taken_at),
      offset: anchor.taken_at_offset,
      source: anchor.taken_at_source,
      manual?:
        if(stack,
          do: Enum.any?(Stacks.files(stack.uuid), &(&1.taken_at_source == "manual")),
          else: file.taken_at_source == "manual"
        ),
      label: format_date(local),
      time: Calendar.strftime(local, "%H:%M"),
      zone: zone(anchor.taken_at_offset),
      source_label: source_label(anchor.taken_at_source),
      date_value: local |> NaiveDateTime.to_date() |> Date.to_iso8601(),
      time_value: Calendar.strftime(local, "%H:%M")
    }
  end

  defp place(file, library, audience, lang) do
    manual? = ManualLocation.manual?(file)

    case {file.latitude, file.longitude, Sharing.place_view(library, audience)} do
      {lat, lon, :exact} when is_number(lat) and is_number(lon) ->
        named(ManualLocation.place_name(file), lat, lon, lang, :exact)
        |> Map.merge(%{
          view: :exact,
          latitude: lat,
          longitude: lon,
          radius: nil,
          manual?: manual?,
          shared: Sharing.locations(library),
          exif?: exif_position?(file)
        })

      {lat, lon, :area} when is_number(lat) and is_number(lon) ->
        {lat, lon, radius} = Sharing.approximate(lat, lon)

        named(nil, lat, lon, lang, :area)
        |> Map.merge(%{
          view: :area,
          latitude: lat,
          longitude: lon,
          radius: radius,
          manual?: false,
          shared: Sharing.locations(library),
          exif?: false
        })

      {lat, lon, :none} when is_number(lat) and is_number(lon) ->
        nil

      _ ->
        if audience == :member,
          do: %{
            view: :missing,
            manual?: manual?,
            exif?: exif_position?(file),
            shared: Sharing.locations(library)
          }
    end
  end

  # The place's name: the one kept with it, else the geocoder's when it is known already.
  # `:lookup` is what to ask the geocoder for in the background when it is not.
  defp named(name, _lat, _lon, _lang, _detail) when is_binary(name),
    do: %{name: name, lookup: nil}

  defp named(nil, lat, lon, lang, detail) do
    case Places.peek(lat, lon, lang, detail) do
      {:ok, name} -> %{name: name, lookup: nil}
      :unknown -> %{name: nil, lookup: {lat, lon, lang, detail}}
      :off -> %{name: nil, lookup: nil}
    end
  end

  defp exif_position?(%StorageFile{metadata: %{"exif" => %{"gps" => %{"latitude" => lat}}}})
       when is_number(lat),
       do: true

  defp exif_position?(_file), do: false

  defp facts(file) do
    exif = (file.metadata || %{})["exif"] || %{}

    %{
      name: file.original_file_name || file.file_name,
      type: file.file_type,
      size: file.size,
      width: file.width,
      height: file.height,
      duration: file.duration,
      camera: camera(exif["camera"] || %{}),
      exposure: exposure(exif["exposure"] || %{})
    }
  end

  defp camera(camera) do
    [camera["make"], camera["model"]]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> dedupe_make()
    |> Enum.join(" ")
    |> blank_nil()
  end

  defp exposure(exposure) do
    [
      exposure["f_number"] && "ƒ/#{exposure["f_number"]}",
      exposure["exposure_time"] && "#{exposure["exposure_time"]} s",
      exposure["focal_length"] && "#{trim_number(exposure["focal_length"])} mm",
      exposure["iso"] && "ISO #{exposure["iso"]}"
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" · ")
    |> blank_nil()
  end

  # "Apple iPhone 17 Pro", but "Canon Canon EOS R5" is said once.
  defp dedupe_make([make, model]) do
    if String.starts_with?(String.downcase(model), String.downcase(make)),
      do: [model],
      else: [make, model]
  end

  defp dedupe_make(parts), do: parts

  defp trim_number(n) when is_float(n),
    do: n |> Float.round(1) |> to_string() |> String.trim_trailing(".0")

  defp trim_number(n), do: to_string(n)

  # ---------------------------------------------------------------------------
  # Changing

  @doc """
  Saves the title and description of `file_uuid` in several languages at once:
  `by_lang` is `%{language => %{"title" => …, "description" => …, "alt" => …}}`. Only the
  site's languages are kept. Returns `{:ok, file}` or `{:error, message}`.
  """
  @spec save_text(Timeline.scope(), String.t(), map(), Scope.t() | nil) ::
          {:ok, StorageFile.t()} | {:error, String.t()}
  def save_text(scope, file_uuid, by_lang, auth) when is_map(by_lang) do
    allowed = enabled_languages()

    by_lang =
      for {lang, %{} = attrs} <- by_lang, lang in allowed, into: %{} do
        {lang,
         attrs
         |> Map.take(~w(title description alt))
         |> Map.filter(fn {_key, value} -> is_binary(value) end)}
      end

    with {:ok, file} <- editable(scope, file_uuid, auth),
         {:ok, file} <- Storage.update_file_details_languages(file, by_lang) do
      Storage.broadcast_files_changed([file.uuid])
      {:ok, file}
    else
      {:error, reason} -> {:error, message(reason)}
    end
  end

  def save_text(_scope, _file_uuid, _by_lang, _auth), do: {:error, message(:invalid)}

  @doc """
  Dates `file_uuid` by hand (`date` `"YYYY-MM-DD"`, `time` `"HH:MM"` or `""` to keep the
  time of day). A photo of a stack moves the whole stack, its cover to the date.
  Returns `{:ok, file_uuids}` or `{:error, message}`.
  """
  @spec set_date(Timeline.scope(), String.t(), String.t(), String.t(), Scope.t() | nil) ::
          {:ok, [String.t()]} | {:error, String.t()}
  def set_date(scope, file_uuid, date, time, auth) do
    with {:ok, file} <- readable(scope, file_uuid, auth),
         {:ok, to} <- parse_date(date, time),
         {:ok, uuids} <- ManualDate.set(dated_together(file), to, auth) do
      {:ok, uuids}
    else
      {:error, reason} -> {:error, message(reason)}
    end
  end

  @doc "Gives `file_uuid` (its whole stack, in one) its own date back."
  @spec reset_date(Timeline.scope(), String.t(), Scope.t() | nil) ::
          {:ok, [String.t()]} | {:error, String.t()}
  def reset_date(scope, file_uuid, auth) do
    with {:ok, file} <- readable(scope, file_uuid, auth),
         {:ok, uuids} <- ManualDate.reset(dated_together(file), auth) do
      {:ok, uuids}
    else
      {:error, reason} -> {:error, message(reason)}
    end
  end

  # A stack's photos move in time together, cover first (`ManualDate.set/3`'s anchor).
  defp dated_together(%StorageFile{stack_uuid: nil, uuid: uuid}), do: [uuid]

  defp dated_together(%StorageFile{stack_uuid: stack_uuid, uuid: uuid}) do
    case stack_uuid |> Stacks.files() |> Enum.filter(&is_nil(&1.trashed_at)) do
      [_, _ | _] = files -> Enum.map(files, & &1.uuid)
      _ -> [uuid]
    end
  end

  @doc """
  Places `file_uuid` at `{latitude, longitude}`, named `name` (may be nil).
  Returns `{:ok, file_uuids}` or `{:error, message}`.
  """
  @spec set_place(
          Timeline.scope(),
          String.t(),
          {number(), number()},
          String.t() | nil,
          Scope.t() | nil
        ) ::
          {:ok, [String.t()]} | {:error, String.t()}
  def set_place(scope, file_uuid, position, name, auth) do
    with {:ok, file} <- readable(scope, file_uuid, auth),
         {:ok, uuids} <- ManualLocation.set([file.uuid], position, auth, name: name) do
      {:ok, uuids}
    else
      {:error, reason} -> {:error, message(reason)}
    end
  end

  @doc """
  A place to offer for a photo with none: that of the photo of the same library taken
  nearest in time to it, within three days, which `auth` may read. Photos of one outing
  are usually of one place, and a scan or a camera without GPS sits among phone photos
  that have one. `%{latitude, longitude, name}` (name may be nil) or nil.
  """
  @spec suggest_place(Timeline.scope(), StorageFile.t(), Scope.t() | nil) :: map() | nil
  def suggest_place(scope, %StorageFile{taken_at: %DateTime{} = at, uuid: uuid}, auth) do
    import Ecto.Query

    window = 3 * 86_400

    with {:ok, query} <- Timeline.files_query(scope, auth),
         %StorageFile{} = near <-
           query
           |> exclude(:order_by)
           |> exclude(:preload)
           |> where([f], f.uuid != ^uuid and not is_nil(f.latitude) and not is_nil(f.longitude))
           |> where(
             [f],
             f.taken_at >= ^DateTime.add(at, -window) and f.taken_at <= ^DateTime.add(at, window)
           )
           |> order_by([f], fragment("abs(extract(epoch from (? - ?)))", f.taken_at, ^at))
           |> limit(1)
           |> PhoenixKit.RepoHelper.repo().one(),
         true <- Libraries.can?(auth, near, :read) do
      %{
        latitude: near.latitude,
        longitude: near.longitude,
        name: ManualLocation.place_name(near)
      }
    else
      _ -> nil
    end
  end

  def suggest_place(_scope, _file, _auth), do: nil

  @doc "Removes the place of `file_uuid`, by hand."
  @spec clear_place(Timeline.scope(), String.t(), Scope.t() | nil) ::
          {:ok, [String.t()]} | {:error, String.t()}
  def clear_place(scope, file_uuid, auth) do
    with {:ok, file} <- readable(scope, file_uuid, auth),
         {:ok, uuids} <- ManualLocation.clear([file.uuid], auth) do
      {:ok, uuids}
    else
      {:error, reason} -> {:error, message(reason)}
    end
  end

  @doc "Gives `file_uuid` the place its camera recorded, or none."
  @spec reset_place(Timeline.scope(), String.t(), Scope.t() | nil) ::
          {:ok, [String.t()]} | {:error, String.t()}
  def reset_place(scope, file_uuid, auth) do
    with {:ok, file} <- readable(scope, file_uuid, auth),
         {:ok, uuids} <- ManualLocation.reset([file.uuid], auth) do
      {:ok, uuids}
    else
      {:error, reason} -> {:error, message(reason)}
    end
  end

  defp readable(scope, file_uuid, auth) do
    case Timeline.readable_file(scope, file_uuid, auth) do
      {:ok, file} -> {:ok, file}
      _ -> {:error, :not_found}
    end
  end

  defp editable(scope, file_uuid, auth) do
    with {:ok, file} <- readable(scope, file_uuid, auth) do
      if is_struct(auth, Scope) and Libraries.can?(auth, file, :edit),
        do: {:ok, file},
        else: {:error, :forbidden}
    end
  end

  @doc false
  def parse_date(date, time) when is_binary(date) do
    time = if is_binary(time), do: String.trim(time), else: ""

    case {Date.from_iso8601(String.trim(date)), time} do
      {{:ok, date}, ""} ->
        {:ok, date}

      {{:ok, date}, time} ->
        with {:ok, time} <- Time.from_iso8601(pad_seconds(time)),
             {:ok, at} <- NaiveDateTime.new(date, time) do
          {:ok, at}
        else
          _ -> {:error, :bad_date}
        end

      _ ->
        {:error, :bad_date}
    end
  end

  def parse_date(_date, _time), do: {:error, :bad_date}

  defp pad_seconds(<<_h::binary-size(2), ":", _m::binary-size(2)>> = time), do: time <> ":00"
  defp pad_seconds(time), do: time

  @doc false
  def message(:implausible_date), do: gettext("That date is before 1826 or in the future.")
  def message(:bad_date), do: gettext("That is not a date.")
  def message(:invalid_position), do: gettext("That is not a place on the map.")
  def message(:forbidden), do: gettext("You may not change this photo.")
  def message(:not_found), do: gettext("This photo is no longer here.")

  def message(:managed),
    do: gettext("This photo is managed elsewhere and cannot be changed here.")

  def message({_lang, %Ecto.Changeset{}}),
    do: gettext("The title or the description is too long.")

  def message(%Ecto.Changeset{}), do: gettext("The title or the description is too long.")
  def message(_other), do: gettext("That could not be done.")

  # ---------------------------------------------------------------------------
  # Words

  @doc "A date as a person says it: \"Thursday, 12 March 1985\", in the page's language."
  @spec format_date(NaiveDateTime.t() | Date.t()) :: String.t()
  def format_date(%NaiveDateTime{} = at), do: format_date(NaiveDateTime.to_date(at))

  def format_date(%Date{} = date) do
    gettext("%{weekday}, %{day} %{month} %{year}",
      weekday: weekday(Date.day_of_week(date)),
      day: date.day,
      month: month_in_date(date.month),
      year: date.year
    )
  end

  @doc ~s(A UTC offset in seconds as "UTC+2", "UTC−3:30"; nil for none.)
  @spec zone(integer() | nil) :: String.t() | nil
  def zone(nil), do: nil
  def zone(0), do: "UTC"

  def zone(seconds) when is_integer(seconds) do
    sign = if seconds < 0, do: "−", else: "+"
    minutes = div(abs(seconds), 60)
    hours = div(minutes, 60)
    rest = rem(minutes, 60)

    if rest == 0,
      do: "UTC#{sign}#{hours}",
      else: "UTC#{sign}#{hours}:#{String.pad_leading(to_string(rest), 2, "0")}"
  end

  def zone(_other), do: nil

  defp source_label("manual"), do: gettext("Set by hand")
  defp source_label("exif"), do: gettext("From the camera")
  defp source_label("container"), do: gettext("From the video")
  defp source_label("filename"), do: gettext("From the file's name")
  defp source_label("inserted_at"), do: gettext("When it was uploaded")
  defp source_label(_other), do: nil

  defp weekday(1), do: gettext("Monday")
  defp weekday(2), do: gettext("Tuesday")
  defp weekday(3), do: gettext("Wednesday")
  defp weekday(4), do: gettext("Thursday")
  defp weekday(5), do: gettext("Friday")
  defp weekday(6), do: gettext("Saturday")
  defp weekday(7), do: gettext("Sunday")

  # A month as it reads inside a date ("12 March"), which some languages decline
  # (Russian "12 марта"), so it is its own translation.
  defp month_in_date(1), do: pgettext("in a date", "January")
  defp month_in_date(2), do: pgettext("in a date", "February")
  defp month_in_date(3), do: pgettext("in a date", "March")
  defp month_in_date(4), do: pgettext("in a date", "April")
  defp month_in_date(5), do: pgettext("in a date", "May")
  defp month_in_date(6), do: pgettext("in a date", "June")
  defp month_in_date(7), do: pgettext("in a date", "July")
  defp month_in_date(8), do: pgettext("in a date", "August")
  defp month_in_date(9), do: pgettext("in a date", "September")
  defp month_in_date(10), do: pgettext("in a date", "October")
  defp month_in_date(11), do: pgettext("in a date", "November")
  defp month_in_date(12), do: pgettext("in a date", "December")

  defp present?(value), do: is_binary(value) and String.trim(value) != ""
  defp blank_nil(value), do: if(present?(value), do: value)
end
