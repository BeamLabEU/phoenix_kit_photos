ExUnit.start()

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

Sandbox.mode(TestRepo, :manual)
