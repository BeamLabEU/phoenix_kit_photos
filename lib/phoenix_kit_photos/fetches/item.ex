defmodule PhoenixKitPhotos.Fetches.Item do
  @moduledoc """
  One file a fetch brought in (`phoenix_kit_photo_fetch_items`), and where it came
  from: the viewer shows `source_url`, `author` and the site for a stored file
  (`PhoenixKitPhotos.Fetches.source_for/1`).

  `status`: `"stored"`, `"duplicate"` (already in this library), `"elsewhere"` (in
  another of the person's libraries) or `"failed"` (`error` says why).
  """

  use Ecto.Schema
  use PhoenixKit.SchemaPrefix

  @primary_key {:uuid, UUIDv7, autogenerate: true}
  @foreign_key_type UUIDv7

  schema "phoenix_kit_photo_fetch_items" do
    field :fetch_uuid, UUIDv7
    field :position, :integer
    field :file_uuid, UUIDv7
    field :status, :string
    field :source_url, :string
    field :title, :string
    field :author, :string
    field :posted_at, :naive_datetime
    field :error, :string

    timestamps(type: :naive_datetime)
  end

  @type t :: %__MODULE__{}
end
