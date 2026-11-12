defmodule PhoenixKitPhotos.Fetches.Link do
  @moduledoc """
  What counts as a link to fetch, and the site it is on.

  A link is one `http` or `https` URL with a host, no user name or password in it, at
  most 2,000 characters. Text around a single URL (a pasted "Look at this:
  https://…") is allowed and dropped; text with no URL, or with several, is not a link.

  This is about what a person meant, not about safety: whatever passes here still
  reaches the network only through the egress proxy
  (`PhoenixKitPhotos.Fetches.Config`), which is what keeps internal addresses out.
  """

  @max_length 2_000
  @url ~r{https?://[^\s<>"'`]+}i

  @doc """
  The link in `text`, normalised (`{:ok, url}`), or `:error` when `text` holds no
  link or more than one.
  """
  @spec parse(String.t() | nil) :: {:ok, String.t()} | :error
  def parse(text) when is_binary(text) do
    case Regex.scan(@url, String.trim(text)) do
      [[candidate]] -> candidate |> trim_trailing_punctuation() |> check()
      _none_or_several -> :error
    end
  end

  def parse(_text), do: :error

  @doc "The site a link is on, for people: its host without `www.` (`flickr.com`)."
  @spec site(String.t()) :: String.t() | nil
  def site(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{host: host} when is_binary(host) and host != "" ->
        host |> String.downcase() |> String.replace_prefix("www.", "")

      _ ->
        nil
    end
  end

  def site(_url), do: nil

  # The same login under another name: an old domain, a short link, a mobile host.
  @aliases %{
    "twitter.com" => "x.com",
    "youtu.be" => "youtube.com",
    "instagr.am" => "instagram.com",
    "fb.com" => "facebook.com",
    "fb.watch" => "facebook.com",
    "redd.it" => "reddit.com"
  }

  @second_levels ~w(co com net org gov ac edu)

  @doc """
  The site a login is kept under: the registered domain of a link or a host, so
  `old.reddit.com` and `www.reddit.com` share `reddit.com`, with a few known aliases
  (`twitter.com` is `x.com`). Nil for something that is not a host.
  """
  @spec login_site(String.t() | nil) :: String.t() | nil
  def login_site(url_or_host) when is_binary(url_or_host) do
    host =
      if String.contains?(url_or_host, "://"),
        do: site(url_or_host),
        else: url_or_host |> String.trim() |> String.downcase()

    with host when is_binary(host) <- host,
         true <- Regex.match?(~r/^[a-z0-9.-]+\.[a-z]{2,}$/, host) do
      labels = String.split(host, ".")

      registered =
        case Enum.reverse(labels) do
          [tld, second, third | _] when byte_size(tld) == 2 and second in @second_levels ->
            Enum.join([third, second, tld], ".")

          [tld, second | _] ->
            second <> "." <> tld
        end

      Map.get(@aliases, registered, registered)
    else
      _ -> nil
    end
  end

  def login_site(_url_or_host), do: nil

  # A link at the end of a sentence carries the sentence's full stop or a closing
  # bracket that is not its own.
  defp trim_trailing_punctuation(url) do
    trimmed = String.replace(url, ~r/[.,;:!?]+$/, "")

    if String.ends_with?(trimmed, ")") and not String.contains?(trimmed, "("),
      do: String.trim_trailing(trimmed, ")"),
      else: trimmed
  end

  defp check(url) do
    with true <- byte_size(url) <= @max_length,
         %URI{scheme: scheme, host: host, userinfo: nil} when scheme in ["http", "https"] <-
           URI.parse(url),
         true <- is_binary(host) and host != "" and String.contains?(host, ".") do
      {:ok, url}
    else
      _ -> :error
    end
  end
end
