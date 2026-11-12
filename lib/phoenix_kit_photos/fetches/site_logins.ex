defmodule PhoenixKitPhotos.Fetches.SiteLogins do
  @moduledoc """
  A person's own logins for sites that need one (Instagram, X…), as the cookies their
  browser holds, exported as `cookies.txt` and pasted in their settings.

    * **Only that site's cookies are kept** (`PhoenixKitPhotos.Fetches.CookiesTxt.for_site/2`):
      browser extensions export every site at once.
    * **Encrypted** with core's `PhoenixKit.Integrations.Encryption` (AES-256-GCM) before
      they are written, and read back only to run a fetch of that person's.
    * **On disk only while a fetch runs**: `cookie_file/3` writes them (mode 0600) into
      the fetch's own folder, which is deleted when the fetch ends.
    * Never shown again once saved: the settings list the site, how many cookies, when
      they were added, and when they last worked or failed.

  A login is kept under its site's registered domain (`Link.login_site/1`), so one
  login serves `www.instagram.com` and `instagram.com`.
  """

  import Ecto.Query

  require Logger

  alias PhoenixKit.Integrations.Encryption
  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKitPhotos.Fetches.{CookiesTxt, Link, SiteLogin}

  @max_bytes 1_000_000

  @doc "A person's logins, by site, without their cookies."
  @spec list(String.t() | Scope.t()) :: [SiteLogin.t()]
  def list(%Scope{} = scope), do: list(Scope.user_uuid(scope))

  def list(user_uuid) when is_binary(user_uuid) do
    from(l in SiteLogin, where: l.user_uuid == ^user_uuid, order_by: l.site)
    |> repo().all()
    |> Enum.map(&%{&1 | cookies: nil})
  end

  def list(_), do: []

  @doc "Whether a person has a login for the site of `url_or_site`."
  @spec has_login?(String.t(), String.t()) :: boolean()
  def has_login?(user_uuid, url_or_site) do
    case Link.login_site(url_or_site) do
      nil ->
        false

      site ->
        repo().exists?(from(l in SiteLogin, where: l.user_uuid == ^user_uuid and l.site == ^site))
    end
  end

  @doc """
  Saves `text` (a pasted cookies.txt) as the person's login for `site` (a site or a
  link to it), replacing any they had. `{:ok, login}` (cookies left out), or
  `{:error, reason}`: `:invalid_site`, `:too_big`, `:not_cookies_txt`, `:empty` (none of
  the cookies is for that site).
  """
  @spec put(Scope.t(), String.t(), String.t()) ::
          {:ok, SiteLogin.t()}
          | {:error, :invalid_site | :too_big | :not_cookies_txt | :empty | :not_allowed}
  def put(%Scope{} = scope, site, text) when is_binary(text) do
    with user_uuid when is_binary(user_uuid) <- Scope.user_uuid(scope) || {:error, :not_allowed},
         site when is_binary(site) <- Link.login_site(site) || {:error, :invalid_site},
         true <- byte_size(text) <= @max_bytes || {:error, :too_big},
         {:ok, kept, count} <- CookiesTxt.for_site(text, site) do
      now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

      %SiteLogin{
        user_uuid: user_uuid,
        site: site,
        cookies: Encryption.encrypt_value(kept),
        cookie_count: count,
        inserted_at: now,
        updated_at: now
      }
      |> repo().insert(
        on_conflict: [
          set: [
            cookies: Encryption.encrypt_value(kept),
            cookie_count: count,
            updated_at: now,
            last_worked_at: nil,
            last_failed_at: nil
          ]
        ],
        conflict_target: [:user_uuid, :site],
        returning: true
      )
      |> case do
        {:ok, login} -> {:ok, %{login | cookies: nil}}
        {:error, _} -> {:error, :not_cookies_txt}
      end
    end
  end

  def put(_scope, _site, _text), do: {:error, :not_allowed}

  @doc "Forgets the person's login for `site`."
  @spec delete(Scope.t(), String.t()) :: :ok
  def delete(%Scope{} = scope, site) do
    with user_uuid when is_binary(user_uuid) <- Scope.user_uuid(scope),
         site when is_binary(site) <- Link.login_site(site) do
      repo().delete_all(
        from(l in SiteLogin, where: l.user_uuid == ^user_uuid and l.site == ^site)
      )
    end

    :ok
  end

  @doc """
  Writes the person's cookies for the site of `url` into `dir` (mode 0600) and returns
  the path, or nil when they have none (or they cannot be decrypted).
  """
  @spec cookie_file(String.t(), String.t(), Path.t()) :: Path.t() | nil
  def cookie_file(user_uuid, url, dir) do
    with site when is_binary(site) <- Link.login_site(url),
         %SiteLogin{cookies: cookies} <-
           repo().one(from(l in SiteLogin, where: l.user_uuid == ^user_uuid and l.site == ^site)),
         {:ok, text} when is_binary(text) <- Encryption.decrypt_value(cookies) do
      path = Path.join(dir, "cookies.txt")
      File.mkdir_p!(dir)
      File.write!(path, "")
      File.chmod!(path, 0o600)
      File.write!(path, text)
      path
    else
      {:error, reason} ->
        Logger.warning("[Fetches] a saved login could not be decrypted: #{inspect(reason)}")
        nil

      _ ->
        nil
    end
  end

  @doc "Notes that the person's login for the site of `url` just worked, or failed."
  @spec mark(String.t(), String.t(), :worked | :failed) :: :ok
  def mark(user_uuid, url, outcome) when outcome in [:worked, :failed] do
    with site when is_binary(site) <- Link.login_site(url) do
      field = if outcome == :worked, do: :last_worked_at, else: :last_failed_at
      now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

      repo().update_all(
        from(l in SiteLogin, where: l.user_uuid == ^user_uuid and l.site == ^site),
        set: [{field, now}]
      )
    end

    :ok
  end

  defp repo, do: PhoenixKit.RepoHelper.repo()
end
