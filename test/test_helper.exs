# `:real_tools` runs the real yt-dlp and gallery-dl against real sites through $FETCH_PROXY
# (`mix test --include real_tools`): it needs the network, so it is left out by default.
ExUnit.start(exclude: [:real_tools])

{:ok, _} = Application.ensure_all_started(:phoenix_kit_photos)

alias Ecto.Adapters.SQL.Sandbox
alias PhoenixKitPhotos.TestRepo

{:ok, _} = TestRepo.start_link()

case TestRepo.query("SELECT taken_on FROM phoenix_kit_files LIMIT 0", []) do
  {:ok, _} ->
    :ok

  {:error, reason} ->
    raise """
    phoenix_kit_files.taken_on is not readable (#{inspect(reason)}).

    Point PGHOST/PGUSER/PGPASSWORD/PGDATABASE (or DB_*) at a database
    already migrated to PhoenixKit V205. This role cannot create one.
    """
end

# This package's own tables (`PhoenixKitPhotos.Migrations`): every statement is
# `IF NOT EXISTS`, so a database that has them already is left as it is.
for statement <- PhoenixKitPhotos.Migrations.up_statements("public") do
  TestRepo.query!(statement, [], log: false)
end

Sandbox.mode(TestRepo, :manual)
