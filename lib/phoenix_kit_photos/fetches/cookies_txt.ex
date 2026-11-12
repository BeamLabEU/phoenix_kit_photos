defmodule PhoenixKitPhotos.Fetches.CookiesTxt do
  @moduledoc """
  The `cookies.txt` a person exports from their browser (the Netscape format both
  yt-dlp and gallery-dl read), kept to one site.

  A line is seven tab-separated fields: domain, whether subdomains match, path,
  secure, expiry (Unix seconds, 0 for a session cookie), name, value. Comments start
  with `#`, except `#HttpOnly_` before a domain, which marks an HTTP-only cookie and is
  kept. Browser extensions export every site's cookies at once, so `for_site/2` keeps
  only the lines whose domain is the site or under it: a person who pastes everything
  gives Fotki their Instagram cookies, not their bank's.
  """

  @header "# Netscape HTTP Cookie File"

  @doc """
  The lines of `text` for `site` (`"instagram.com"`), as a cookies.txt the tools read,
  with how many cookies it holds: `{:ok, text, count}`, or `{:error, :empty}` when
  none is for that site, or `{:error, :not_cookies_txt}` when the text is not in this
  format at all.
  """
  @spec for_site(String.t(), String.t()) ::
          {:ok, String.t(), pos_integer()} | {:error, :empty | :not_cookies_txt}
  def for_site(text, site) when is_binary(text) and is_binary(site) do
    lines = parse(text)
    site = site |> String.downcase() |> String.replace_prefix("www.", "")

    case {lines, Enum.filter(lines, &for_site?(&1, site))} do
      {[], _} ->
        {:error, :not_cookies_txt}

      {_lines, []} ->
        {:error, :empty}

      {_lines, kept} ->
        {:ok, Enum.join([@header | Enum.map(kept, & &1.line)], "\n") <> "\n", length(kept)}
    end
  end

  @doc "The cookie lines of `text`, each as `%{domain, name, line}`; anything else dropped."
  @spec parse(String.t()) :: [%{domain: String.t(), name: String.t(), line: String.t()}]
  def parse(text) when is_binary(text) do
    text
    |> String.split(~r/\r?\n/)
    |> Enum.flat_map(&cookie_line/1)
  end

  defp cookie_line(line) do
    line = String.trim_trailing(line, "\r")

    with false <- line == "",
         false <- String.starts_with?(line, "#") and not String.starts_with?(line, "#HttpOnly_"),
         [domain, flag, path, secure, expiry, name, _value] <- String.split(line, "\t"),
         true <- flag in ["TRUE", "FALSE"] and secure in ["TRUE", "FALSE"],
         true <- String.starts_with?(path, "/"),
         {_n, ""} <- Integer.parse(expiry) do
      bare = domain |> String.replace_prefix("#HttpOnly_", "") |> String.downcase()
      [%{domain: bare, name: name, line: line}]
    else
      _ -> []
    end
  end

  # The site itself, a host under it (`.www.instagram.com`), or a parent of it that is
  # more than a bare top-level domain (`.reddit.com` for `old.reddit.com`; never `.com`).
  defp for_site?(%{domain: domain}, site) do
    domain = String.trim_leading(domain, ".")

    domain == site or String.ends_with?(domain, "." <> site) or
      (String.contains?(domain, ".") and String.ends_with?(site, "." <> domain))
  end
end
