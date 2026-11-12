defmodule PhoenixKitPhotos.StagingSweepJob do
  @moduledoc """
  Deletes staged uploads (`PhoenixKitPhotos.UploadStaging`) that a crash left behind:
  older than a day, and not waiting in a `PhoenixKitPhotos.StoreUploadJob`. A job's
  retries end within about twenty minutes, so a day old is well past any of them.

  It also tidies fetches from a link (`PhoenixKitPhotos.Fetches.sweep/0`): looks
  nobody confirmed, fetches whose job died, folders left behind.

  It schedules itself (`schedule/0`, called whenever the uploader stages a file or a
  fetch starts): at
  most one is waiting at a time, an hour out. A host needs no cron entry for it, so a
  host's config never names a module an older release of this package lacks.
  """

  use Oban.Worker,
    queue: :photo_uploads,
    max_attempts: 3,
    unique: [period: :infinity, states: [:available, :scheduled]]

  import Ecto.Query

  require Logger

  alias PhoenixKitPhotos.{StoreUploadJob, UploadStaging}

  @waiting ~w(available scheduled executing retryable)

  @doc "Makes sure a sweep is due within the hour. Never fails the caller."
  @spec schedule() :: :ok
  def schedule do
    _ = Oban.insert(new(%{}, schedule_in: 3600))
    :ok
  rescue
    _ -> :ok
  end

  @impl Oban.Worker
  def perform(_job) do
    removed = UploadStaging.sweep(waiting())
    if removed > 0, do: Logger.info("[PhotoUploader] removed #{removed} stale staged upload(s)")
    PhoenixKitPhotos.Fetches.sweep()
    :ok
  end

  # The staged files a store job still waits to store.
  defp waiting do
    worker = inspect(StoreUploadJob)

    from(j in Oban.Job,
      where: j.worker == ^worker and j.state in @waiting,
      select: fragment("?->>'staged'", j.args)
    )
    |> PhoenixKit.RepoHelper.repo().all(prefix: Oban.config().prefix)
    |> MapSet.new()
  end
end
