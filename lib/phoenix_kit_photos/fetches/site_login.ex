defmodule PhoenixKitPhotos.Fetches.SiteLogin do
  @moduledoc """
  A person's own cookies for a site that needs a login
  (`phoenix_kit_photo_site_logins`). `cookies` is encrypted
  (`PhoenixKit.Integrations.Encryption`); `PhoenixKitPhotos.Fetches.SiteLogins` is the
  only reader and writer.
  """

  use Ecto.Schema
  use PhoenixKit.SchemaPrefix

  @primary_key {:uuid, UUIDv7, autogenerate: true}
  @foreign_key_type UUIDv7

  schema "phoenix_kit_photo_site_logins" do
    field :user_uuid, UUIDv7
    field :site, :string
    field :cookies, :string, redact: true
    field :cookie_count, :integer, default: 0
    field :last_worked_at, :naive_datetime
    field :last_failed_at, :naive_datetime

    timestamps(type: :naive_datetime)
  end

  @type t :: %__MODULE__{}
end
