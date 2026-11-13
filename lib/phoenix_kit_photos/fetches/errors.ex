defmodule PhoenixKitPhotos.Fetches.Errors do
  @moduledoc """
  Why a fetch could not be done, read from what the tool said (`classify/1`), and what
  a person is told (`message/2`).

  The tools' messages are English and change between versions; the codes do not. A
  message the patterns below do not know is `"failed"`, and the tool's own last line is
  kept on the fetch (`error`) for whoever looks into it.
  """

  use Gettext, backend: PhoenixKitPhotos.Gettext

  @codes ~w(unsupported needs_login blocked not_found address too_long too_big live nothing
            timeout stalled quota_exceeded not_allowed email_unconfirmed failed)

  @doc "Every code."
  def codes, do: @codes

  @doc """
  The code for a tool's output (`text`: its stderr, or the end of it). Checked in this
  order: the proxy refused an internal address, the site wants a login, the site
  refused the server, the link is not something either tool reads, it does not exist.
  """
  @spec classify(String.t()) :: String.t()
  def classify(text) when is_binary(text) do
    cond do
      text =~ ~r/407|Proxy Authentication Required|Tunnel connection failed: 40[37]/i ->
        "address"

      text =~
          ~r/AuthRequired|AuthorizationError|AuthenticationError|authenticated cookies|log ?in (to|required)|login required|sign in to|requires? (a )?log ?in|redirect(ed)? to (the )?login|use --cookies|account (is )?private|private (account|video)|NotFoundError: Requested user could not be found/i ->
        "needs_login"

      text =~
          ~r/ChallengeError|blocked by network security|confirm you.?re not a bot|HTTP Error 403|403 Forbidden|HTTP Error 429|429 Too Many Requests|rate.?limit/i ->
        "blocked"

      text =~ ~r/Unsupported URL|No suitable extractor/i ->
        "unsupported"

      text =~
          ~r/HTTP Error 404|404 Not Found|NotFoundError|Video unavailable|does not exist|has been removed|is not available/i ->
        "not_found"

      text =~ ~r/File is larger than max-filesize|larger than max/i ->
        "too_big"

      text =~ ~r/does not pass filter|is live|live event/i ->
        "too_long"

      true ->
        "failed"
    end
  end

  def classify(_text), do: "failed"

  @doc "The last line of a tool's output that reads like an error, for the record."
  @spec last_error_line(String.t()) :: String.t() | nil
  def last_error_line(text) when is_binary(text) do
    text
    |> String.split(~r/\r?\n/, trim: true)
    |> Enum.reverse()
    |> Enum.find(&(&1 =~ ~r/error|warning|fail/i))
    |> case do
      nil -> nil
      line -> String.slice(line, 0, 500)
    end
  end

  def last_error_line(_text), do: nil

  @doc "What a person is told for a code. `site` names the site where it helps."
  @spec message(String.t() | nil, String.t() | nil) :: String.t()
  def message(code, site \\ nil)

  def message("unsupported", _site),
    do:
      gettext(
        "Nothing here can be fetched: this site is not one Fotki can read, or the link is not to a photo, video or album."
      )

  def message("needs_login", site) when is_binary(site),
    do:
      gettext(
        "%{site} needs a login to show this. Add your %{site} login in Site logins, then try again.",
        site: site
      )

  def message("needs_login", _site),
    do:
      gettext(
        "This site needs a login to show this. Add your login in Site logins, then try again."
      )

  def message("blocked", site) when is_binary(site),
    do:
      gettext("%{site} refused to answer the server, or asked it to slow down. Try again later.",
        site: site
      )

  def message("blocked", _site),
    do:
      gettext("The site refused to answer the server, or asked it to slow down. Try again later.")

  def message("not_found", _site),
    do: gettext("Nothing was found at this link. It may have been removed, or it is private.")

  def message("address", _site), do: gettext("This address cannot be fetched.")
  def message("too_long", _site), do: gettext("This video is longer than fetching allows.")
  def message("too_big", _site), do: gettext("This file is larger than fetching allows.")
  def message("live", _site), do: gettext("A live stream cannot be fetched.")
  def message("nothing", _site), do: gettext("No photos or videos were found at this link.")

  def message("timeout", _site),
    do:
      gettext(
        "This took too long. A link to one post, album or video works better than one to a whole profile."
      )

  def message("stalled", _site), do: gettext("The download stopped moving and was ended.")

  def message("quota_exceeded", _site),
    do: gettext("There is no room left in this library's storage.")

  def message("not_allowed", _site), do: gettext("You may not add to this library.")

  def message("email_unconfirmed", _site),
    do: gettext("Confirm your email address first: open the link you were sent.")

  def message(_code, _site), do: gettext("Fetching did not work.")
end
