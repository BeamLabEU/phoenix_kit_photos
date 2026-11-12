defmodule PhoenixKitPhotos.Fetches.Notify do
  @moduledoc """
  Telling a person a fetch ended, when they may have left (D13 of the plan).

    * **The bell**: a fetch that ran a minute or longer and ended `"done"` or
      `"failed"` is logged with `PhoenixKit.Activity.log/3` as a system action
      (`photos.fetch_done` / `photos.fetch_failed`) aimed at the person, which core's
      notifications turn into their bell entry. The link is the host's to give
      (`:link` in the config, `{module, function}` called with the fetch); without it
      the entry has none.
    * **The host, when the look ends**: `:on_looked` (`looked/1`).
    * **The host**: `:on_finished` (`{module, function}`), if set, is called with every
      ended fetch, short ones included: Fotki answers a fetch that came from its
      Telegram bot in that chat, and tells a linked person on Telegram about a long one
      (`long?/1` says which).

  Neither may break the fetch: anything they raise is logged.
  """

  use Gettext, backend: PhoenixKitPhotos.Gettext

  require Logger

  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Utils.RecipientLocale
  alias PhoenixKitPhotos.Fetches.{Config, Errors, Fetch}

  @long_s 60

  @doc "Whether a fetch ran long enough to be told about (a minute or more)."
  @spec long?(Fetch.t()) :: boolean()
  def long?(%Fetch{
        started_at: %NaiveDateTime{} = started,
        finished_at: %NaiveDateTime{} = finished
      }),
      do: NaiveDateTime.diff(finished, started) >= @long_s

  def long?(_fetch), do: false

  @doc """
  Tells the host that the look at `fetch` ended (`"ready"` or `"unavailable"`), through
  `:on_looked` (`{module, function}`): a fetch that came from somewhere without the
  dialog (Fotki's Telegram bot) asks for the confirmation there.
  """
  @spec looked(Fetch.t()) :: :ok
  def looked(%Fetch{} = fetch) do
    call_host(Config.get(:on_looked), fetch)
    :ok
  end

  @doc "Tells the person (and the host) that `fetch` ended."
  @spec finished(Fetch.t()) :: :ok
  def finished(%Fetch{} = fetch) do
    if long?(fetch) and fetch.status in ["done", "failed"], do: bell(fetch)
    call_host(Config.get(:on_finished), fetch)
    :ok
  end

  defp bell(fetch) do
    user = Auth.get_user(fetch.user_uuid)
    locale = if user, do: RecipientLocale.base(user)

    text =
      Gettext.with_locale(
        PhoenixKitPhotos.Gettext,
        locale || Gettext.get_locale(PhoenixKitPhotos.Gettext),
        fn ->
          text(fetch)
        end
      )

    metadata =
      %{"notification_text" => text, "site" => fetch.site}
      |> put_link(link(fetch))

    PhoenixKit.Activity.log(
      "photos",
      if(fetch.status == "done", do: "photos.fetch_done", else: "photos.fetch_failed"),
      mode: "auto",
      resource_type: "photo_fetch",
      resource_uuid: to_string(fetch.uuid),
      target_uuid: to_string(fetch.user_uuid),
      metadata: metadata
    )
  rescue
    error -> Logger.warning("[Fetches] the bell notification failed: #{Exception.message(error)}")
  end

  @doc false
  def text(%Fetch{status: "done"} = fetch) do
    saved = (fetch.progress || %{})["saved"] || 0
    title = (fetch.info || %{})["title"]

    cond do
      saved == 0 ->
        gettext("Fetched from %{site}: everything was already in your library.", site: fetch.site)

      is_binary(title) ->
        ngettext(
          "Fetched from %{site}: %{title} (%{count} file).",
          "Fetched from %{site}: %{title} (%{count} files).",
          saved,
          site: fetch.site,
          title: title
        )

      true ->
        ngettext(
          "Fetched %{count} file from %{site}.",
          "Fetched %{count} files from %{site}.",
          saved,
          site: fetch.site
        )
    end
  end

  def text(%Fetch{} = fetch) do
    gettext("Fetching from %{site} did not work: %{reason}",
      site: fetch.site,
      reason: Errors.message(fetch.error_code, fetch.site)
    )
  end

  defp put_link(metadata, link) when is_binary(link),
    do: Map.put(metadata, "notification_link", link)

  defp put_link(metadata, _link), do: metadata

  defp link(fetch), do: call_host(Config.get(:link), fetch)

  defp call_host({module, function}, fetch) when is_atom(module) and is_atom(function) do
    apply(module, function, [fetch])
  rescue
    error ->
      Logger.warning(
        "[Fetches] #{inspect(module)}.#{function}/1 failed: #{Exception.message(error)}"
      )

      nil
  end

  defp call_host(_none, _fetch), do: nil
end
