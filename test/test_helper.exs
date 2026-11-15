# `:real_tools` runs the real yt-dlp and gallery-dl against real sites through $FETCH_PROXY
# (`mix test --include real_tools`): it needs the network, so it is left out by default.
ExUnit.start(exclude: [:real_tools])

{:ok, _} = Application.ensure_all_started(:phoenix_kit_photos)

alias Ecto.Adapters.SQL.Sandbox
alias PhoenixKitPhotos.TestRepo

{:ok, _} = TestRepo.start_link()

# Core's chain first, up to whatever core this run resolved: a database left at an
# older core (V227 against core 3.6's V232) otherwise fails half the suite on a
# missing column. Idempotent; a current database is left as it is.
PhoenixKit.Migration.ensure_current(TestRepo, log: false)

# This package's own tables (`PhoenixKitPhotos.Migrations`): every statement is
# `IF NOT EXISTS`, so a database that has them already is left as it is.
for statement <- PhoenixKitPhotos.Migrations.up_statements("public") do
  TestRepo.query!(statement, [], log: false)
end

Sandbox.mode(TestRepo, :manual)
