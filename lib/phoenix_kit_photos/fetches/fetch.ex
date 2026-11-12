defmodule PhoenixKitPhotos.Fetches.Fetch do
  @moduledoc """
  One link a person asked to have fetched into a library (`phoenix_kit_photo_fetches`,
  `PhoenixKitPhotos.Migrations` V1). `PhoenixKitPhotos.Fetches` is the way in.

  ## Status

    * `"probing"` — the look before fetching runs (`ProbeJob`).
    * `"ready"` — the look found something; the dialog waits for the person.
    * `"unavailable"` — the look found nothing that can be fetched; `error_code` says why.
    * `"queued"` — confirmed, waiting for its turn (`FetchJob`).
    * `"running"` — downloading and saving.
    * `"done"`, `"failed"`, `"cancelled"` — ended. A fetch that saved some files and
      failed on others is `"done"`, with the failures counted in `progress`.

  ## Maps

    * `info` — what the look found (`YtDlp.probe_info/2`, `GalleryDl.probe_info/2`).
    * `choices` — `"quality"` (`"default"`/`"best"`) and `"items"` (the entries picked).
    * `progress` — `"phase"`, `"item"`, `"items"`, `"bytes"`, `"total_bytes"`,
      `"speed"`, `"eta"`, `"saved"`, `"duplicates"`, `"failed"`, `"title"`.
    * `origin_data` — what the place it came from needs to answer (the Telegram chat).
  """

  use Ecto.Schema
  use PhoenixKit.SchemaPrefix

  import Ecto.Changeset

  @primary_key {:uuid, UUIDv7, autogenerate: true}
  @foreign_key_type UUIDv7

  @statuses ~w(probing ready unavailable queued running done failed cancelled)
  @open ~w(probing ready unavailable)
  @active ~w(queued running)
  @ended ~w(done failed cancelled)

  schema "phoenix_kit_photo_fetches" do
    field :user_uuid, UUIDv7
    field :library_uuid, UUIDv7
    field :url, :string
    field :origin, :string, default: "web"
    field :origin_data, :map, default: %{}
    field :status, :string
    field :tool, :string
    field :site, :string
    field :info, :map, default: %{}
    field :choices, :map, default: %{}
    field :progress, :map, default: %{}
    field :error_code, :string
    field :error, :string
    field :rights_confirmed_at, :naive_datetime
    field :rights_wording, :string
    field :started_at, :naive_datetime
    field :finished_at, :naive_datetime
    field :dismissed_at, :naive_datetime

    timestamps(type: :naive_datetime)
  end

  @type t :: %__MODULE__{}

  @doc "Every status."
  def statuses, do: @statuses
  @doc "Statuses before the person confirmed."
  def open_statuses, do: @open
  @doc "Statuses of a fetch on its way."
  def active_statuses, do: @active
  @doc "Statuses of a fetch that ended."
  def ended_statuses, do: @ended

  @doc false
  def create_changeset(attrs) do
    %__MODULE__{}
    |> cast(attrs, [:user_uuid, :library_uuid, :url, :origin, :origin_data, :status, :site])
    |> validate_required([:user_uuid, :library_uuid, :url, :status])
    |> validate_inclusion(:status, @statuses)
    |> validate_inclusion(:origin, ~w(web telegram))
    |> validate_length(:url, max: 2_000)
  end
end
