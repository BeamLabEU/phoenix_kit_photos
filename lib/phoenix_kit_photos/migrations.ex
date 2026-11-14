defmodule PhoenixKitPhotos.Migrations do
  @moduledoc """
  The tables this package owns, as a versioned chain that core's
  `mix phoenix_kit.update` finds through `PhoenixKitPhotos.migration_module/0` and runs
  through a wrapper migration it writes in the host (`*_photos_update_v00_to_v01.exs`).
  Same protocol as the other modules' chains (core's
  `dev_docs/plans/2026-10-25-module-table-ownership.md`): `current_version/0`,
  `migrated_version_runtime/1`, an idempotent `up/1` and a version-aware `down/1`.

  ## V1: fetching from a link

  `PhoenixKitPhotos.Fetch` (a link pasted into a library, fetched on the server with
  yt-dlp or gallery-dl):

    * **`phoenix_kit_photo_fetches`**: one row per link a person asked for. Who
      (`user_uuid`) and into which library (`library_uuid`, both cascade), the URL,
      where it came from (`origin`: `web` or `telegram`), its `status`, which tool reads
      it (`tool`) and the site (`site`), what the look before fetching found (`info`),
      what the person chose (`choices`: quality, which items), how far it is
      (`progress`), the error, and **the rights confirmation**: when it was given
      (`rights_confirmed_at`) and which wording was shown (`rights_wording`).
      `dismissed_at` hides a finished fetch from the person's list without losing it.
    * **`phoenix_kit_photo_fetch_items`**: what a fetch brought in, one row per file:
      the stored file (`file_uuid`, `SET NULL` when the file goes), its place in the
      fetch, and where it came from (`source_url`, `title`, `author`, `posted_at`),
      which the viewer shows. Indexed by file, for that.
    * **`phoenix_kit_photo_site_logins`**: a person's own cookies for a site that needs
      a login (one row per person and site), encrypted with core's
      `PhoenixKit.Integrations.Encryption` before they are written.

  ## V2: chapters

  `PhoenixKitPhotos.Chapter` (a stretch of a library's time with a name: a trip, a move):

    * **`phoenix_kit_photo_chapters`**: the library (`library_uuid`, cascade), what it is
      called (`title`, `emoji`, `description`, a preset `color`), when (`starts_on`, and
      `ends_on` when it has an end), the photo chosen as its cover (`cover_file_uuid`,
      `SET NULL`) and who made it (`created_by_uuid`, `SET NULL`). Indexed by library and
      start. A **sub-chapter** names its chapter in `parent_uuid` (one level; deleting a
      chapter deletes its sub-chapters).

  The version is a `pkphotos_schema:<N>` comment on `phoenix_kit_photo_fetches`; no
  table reads as 0.

  ## Down

  To 1 drops the chapters. To 0 drops the three tables (fetch history, sources and saved logins go; the stored
  files stay in their libraries). These tables were never core's, so there is nothing
  to give back.

  ## Adding a version

  Append its statements to `up_statements/2` behind `target >= N` (never edit V1's:
  hosts past V1 never run them again), give `down_statements/2` its way back, and bump
  `@current_version`.
  """

  use Ecto.Migration

  alias PhoenixKit.Migrations.Postgres.Helpers

  @current_version 2
  @marker_prefix "pkphotos_schema:"
  @version_table "phoenix_kit_photo_fetches"

  @spec current_version() :: pos_integer()
  def current_version, do: @current_version

  @doc "The table carrying the `pkphotos_schema:<N>` marker."
  @spec version_table() :: String.t()
  def version_table, do: @version_table

  @doc "The chain version read from inside a migration (the migration's repo)."
  def migrated_version(opts \\ []) do
    prefix = validated_prefix(opts)
    %{rows: rows} = repo().query!(marker_query(), [prefix, @version_table])
    rows |> List.first() |> marker_to_version()
  end

  @doc """
  The chain version applied in the database, read outside a migration (what core's
  update and status tasks call): the marker's number, or 0 when the table is missing.
  A pool that is not running answers 0 rather than crashing the caller.
  """
  def migrated_version_runtime(opts \\ []) do
    prefix = validated_prefix(opts)

    case PhoenixKit.RepoHelper.repo().query(marker_query(), [prefix, @version_table]) do
      {:ok, %{rows: rows}} -> rows |> List.first() |> marker_to_version()
      _ -> 0
    end
  rescue
    e in ArgumentError -> reraise e, __STACKTRACE__
    _ -> 0
  catch
    :exit, _ -> 0
  end

  @doc "Applies every version up to `:version` (default `current_version/0`); idempotent."
  def up(opts \\ []) do
    prefix = validated_prefix(opts)

    target =
      if is_list(opts), do: Keyword.get(opts, :version, @current_version), else: @current_version

    Helpers.ensure_uuid_v7_function(prefix)

    prefix
    |> up_statements(target)
    |> Enum.each(&execute/1)
  end

  @doc "Rolls back to `:version` (default 0). See the moduledoc for what 0 drops."
  def down(opts \\ []) do
    prefix = validated_prefix(opts)
    target = if is_list(opts), do: Keyword.get(opts, :version, 0), else: 0

    prefix
    |> down_statements(target)
    |> Enum.each(&execute/1)
  end

  @doc """
  The SQL `up/1` runs, as data. Every statement is idempotent (`IF NOT EXISTS`), so a
  replay changes nothing; tests run it to build the tables in a database migrated by
  core alone.
  """
  @spec up_statements(String.t(), pos_integer()) :: [String.t()]
  def up_statements(prefix \\ "public", target \\ @current_version)

  def up_statements(prefix, target) when is_integer(target) and target >= 1 do
    prefix = validated_prefix(prefix: prefix)
    p = "#{prefix}."
    target = min(target, @current_version)

    List.flatten([
      v1_statements(p),
      if(target >= 2, do: v2_statements(p), else: []),
      "COMMENT ON TABLE #{p}#{@version_table} IS '#{@marker_prefix}#{target}'"
    ])
  end

  @doc "The SQL `down/1` runs, as data."
  @spec down_statements(String.t(), non_neg_integer()) :: [String.t()]
  def down_statements(prefix \\ "public", target \\ 0)
      when is_integer(target) and target >= 0 do
    prefix = validated_prefix(prefix: prefix)
    p = "#{prefix}."

    if target >= 1 do
      List.flatten([
        if(target < 2, do: ["DROP TABLE IF EXISTS #{p}phoenix_kit_photo_chapters"], else: []),
        "COMMENT ON TABLE #{p}#{@version_table} IS '#{@marker_prefix}#{min(target, @current_version)}'"
      ])
    else
      [
        "DROP TABLE IF EXISTS #{p}phoenix_kit_photo_chapters",
        "DROP TABLE IF EXISTS #{p}phoenix_kit_photo_fetch_items",
        "DROP TABLE IF EXISTS #{p}phoenix_kit_photo_fetches",
        "DROP TABLE IF EXISTS #{p}phoenix_kit_photo_site_logins"
      ]
    end
  end

  # ── V1 ────────────────────────────────────────────────────────────────────

  defp v1_statements(p) do
    id = "#{p}uuid_generate_v7()"

    [
      """
      CREATE TABLE IF NOT EXISTS #{p}phoenix_kit_photo_fetches (
        uuid uuid PRIMARY KEY DEFAULT #{id},
        user_uuid uuid NOT NULL REFERENCES #{p}phoenix_kit_users(uuid) ON DELETE CASCADE,
        library_uuid uuid NOT NULL REFERENCES #{p}phoenix_kit_storage_libraries(uuid) ON DELETE CASCADE,
        url text NOT NULL,
        origin character varying(20) NOT NULL DEFAULT 'web',
        origin_data jsonb NOT NULL DEFAULT '{}'::jsonb,
        status character varying(20) NOT NULL,
        tool character varying(20),
        site character varying(255),
        info jsonb NOT NULL DEFAULT '{}'::jsonb,
        choices jsonb NOT NULL DEFAULT '{}'::jsonb,
        progress jsonb NOT NULL DEFAULT '{}'::jsonb,
        error_code character varying(40),
        error text,
        rights_confirmed_at timestamp(0) without time zone,
        rights_wording character varying(20),
        started_at timestamp(0) without time zone,
        finished_at timestamp(0) without time zone,
        dismissed_at timestamp(0) without time zone,
        inserted_at timestamp(0) without time zone NOT NULL DEFAULT now(),
        updated_at timestamp(0) without time zone NOT NULL DEFAULT now()
      )
      """,
      "CREATE INDEX IF NOT EXISTS phoenix_kit_photo_fetches_user_index ON #{p}phoenix_kit_photo_fetches (user_uuid, inserted_at DESC)",
      "CREATE INDEX IF NOT EXISTS phoenix_kit_photo_fetches_library_index ON #{p}phoenix_kit_photo_fetches (library_uuid, status)",
      """
      CREATE TABLE IF NOT EXISTS #{p}phoenix_kit_photo_fetch_items (
        uuid uuid PRIMARY KEY DEFAULT #{id},
        fetch_uuid uuid NOT NULL REFERENCES #{p}phoenix_kit_photo_fetches(uuid) ON DELETE CASCADE,
        position integer NOT NULL,
        file_uuid uuid REFERENCES #{p}phoenix_kit_files(uuid) ON DELETE SET NULL,
        status character varying(20) NOT NULL,
        source_url text,
        title text,
        author character varying(255),
        posted_at timestamp(0) without time zone,
        error text,
        inserted_at timestamp(0) without time zone NOT NULL DEFAULT now(),
        updated_at timestamp(0) without time zone NOT NULL DEFAULT now()
      )
      """,
      "CREATE INDEX IF NOT EXISTS phoenix_kit_photo_fetch_items_fetch_index ON #{p}phoenix_kit_photo_fetch_items (fetch_uuid, position)",
      "CREATE INDEX IF NOT EXISTS phoenix_kit_photo_fetch_items_file_index ON #{p}phoenix_kit_photo_fetch_items (file_uuid) WHERE file_uuid IS NOT NULL",
      """
      CREATE TABLE IF NOT EXISTS #{p}phoenix_kit_photo_site_logins (
        uuid uuid PRIMARY KEY DEFAULT #{id},
        user_uuid uuid NOT NULL REFERENCES #{p}phoenix_kit_users(uuid) ON DELETE CASCADE,
        site character varying(100) NOT NULL,
        cookies text NOT NULL,
        cookie_count integer NOT NULL DEFAULT 0,
        last_worked_at timestamp(0) without time zone,
        last_failed_at timestamp(0) without time zone,
        inserted_at timestamp(0) without time zone NOT NULL DEFAULT now(),
        updated_at timestamp(0) without time zone NOT NULL DEFAULT now()
      )
      """,
      "CREATE UNIQUE INDEX IF NOT EXISTS phoenix_kit_photo_site_logins_user_site_index ON #{p}phoenix_kit_photo_site_logins (user_uuid, site)"
    ]
  end

  # ── V2 ────────────────────────────────────────────────────────────────────

  defp v2_statements(p) do
    id = "#{p}uuid_generate_v7()"

    [
      """
      CREATE TABLE IF NOT EXISTS #{p}phoenix_kit_photo_chapters (
        uuid uuid PRIMARY KEY DEFAULT #{id},
        library_uuid uuid NOT NULL REFERENCES #{p}phoenix_kit_storage_libraries(uuid) ON DELETE CASCADE,
        parent_uuid uuid REFERENCES #{p}phoenix_kit_photo_chapters(uuid) ON DELETE CASCADE,
        title character varying(120) NOT NULL,
        emoji character varying(16),
        description text,
        color character varying(20),
        starts_on date NOT NULL,
        ends_on date,
        cover_file_uuid uuid REFERENCES #{p}phoenix_kit_files(uuid) ON DELETE SET NULL,
        created_by_uuid uuid REFERENCES #{p}phoenix_kit_users(uuid) ON DELETE SET NULL,
        inserted_at timestamp(0) without time zone NOT NULL DEFAULT now(),
        updated_at timestamp(0) without time zone NOT NULL DEFAULT now(),
        CONSTRAINT phoenix_kit_photo_chapters_dates CHECK (ends_on IS NULL OR ends_on >= starts_on)
      )
      """,
      "CREATE INDEX IF NOT EXISTS phoenix_kit_photo_chapters_library_index ON #{p}phoenix_kit_photo_chapters (library_uuid, starts_on)"
    ]
  end

  # ── Version marker ────────────────────────────────────────────────────────

  defp marker_query do
    """
    SELECT obj_description(c.oid, 'pg_class')
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = $1 AND c.relname = $2 AND c.relkind = 'r'
    """
  end

  defp marker_to_version([@marker_prefix <> n]) do
    case Integer.parse(n) do
      {version, ""} -> version
      _ -> 0
    end
  end

  defp marker_to_version(_), do: 0

  defp validated_prefix(opts) do
    prefix =
      case opts do
        opts when is_list(opts) -> Keyword.get(opts, :prefix, "public")
        %{} = opts -> Map.get(opts, :prefix, "public")
        _ -> "public"
      end

    Helpers.validate_prefix!(prefix)
    prefix
  end
end
