defmodule PhoenixKitPhotos.TestRepo do
  @moduledoc false
  use Ecto.Repo,
    otp_app: :phoenix_kit,
    adapter: Ecto.Adapters.Postgres
end
