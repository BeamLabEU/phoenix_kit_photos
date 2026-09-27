import Config

# This role cannot create databases. Tests run in a sandbox transaction
# against an already-migrated PhoenixKit database (Fotki's dev database
# when PG* / DB_* point at it). Inserts roll back.
env = fn key, fallback, default ->
  case System.get_env(key) do
    value when is_binary(value) and value != "" ->
      value

    _ ->
      case System.get_env(fallback) do
        value when is_binary(value) and value != "" -> value
        _ -> default
      end
  end
end

config :phoenix_kit, repo: PhoenixKitPhotos.TestRepo

config :phoenix_kit, PhoenixKitPhotos.TestRepo,
  username: env.("PGUSER", "DB_USERNAME", "postgres"),
  password: env.("PGPASSWORD", "DB_PASSWORD", "postgres"),
  hostname: env.("PGHOST", "DB_HOSTNAME", "localhost"),
  port: env.("PGPORT", "DB_PORT", "5432") |> String.to_integer(),
  database: env.("PGDATABASE", "DB_DATABASE", "phoenix_kit_photos_test"),
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: 10

config :phoenix_kit, secret_key_base: String.duplicate("a", 64)
config :phoenix_kit, url_prefix: ""

config :logger, level: :warning

config :phoenix_kit_photos, PhoenixKitPhotos.TestEndpoint,
  secret_key_base: String.duplicate("b", 64),
  live_view: [signing_salt: "photos-test"],
  pubsub_server: PhoenixKitPhotos.TestPubSub,
  server: false
