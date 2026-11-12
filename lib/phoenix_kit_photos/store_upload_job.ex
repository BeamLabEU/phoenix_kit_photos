defmodule PhoenixKitPhotos.StoreUploadJob do
  @moduledoc """
  Stores one staged upload (`PhoenixKitPhotos.UploadStaging`) with `Uploads.store/4`,
  off the page, and tells the page what became of it.

  Runs in the `photo_uploads` queue, which the host declares in its Oban config
  (`photo_uploads: 4` is plenty for one node). The uploader only hands files to this
  job when that queue runs on this node (`available?/0`); otherwise it stores them
  inline as before.

  ## What becomes of a file

    * Stored (`{:added | :duplicate | :elsewhere, file}`) or refused for good
      (`:not_allowed`, `:email_unconfirmed`, `:unsupported_type`, `:quota_exceeded`,
      `:file_missing`): the page is told, the staged file is deleted, the job ends.
    * Anything else (storage slow or down, a timeout, `:failed`): tried again after
      5 s, 15 s, 30 s, 1, 2, 5 and 10 minutes, the staged file kept meanwhile, and the
      page told it is being retried. After the last attempt the page gets the error and
      the staged file goes.

  The store runs as the uploader: their account is read again
  (`SessionRef.scope_for_user/1`), so one that was deactivated meanwhile stores nothing,
  and `Uploads.store/4` checks again that they may add to the library. An account whose
  email is not confirmed is refused as `:email_unconfirmed`, not as `:not_allowed`: the
  page tells the person to open the link they were sent, and the refusal is logged.

  ## Telling the page

  `PhoenixKit.PubSub.Manager.broadcast/2` on the topic the page gave
  (`PhoenixKitPhotos.LiveUpdates` makes one per page), as
  `{:phoenix_kit_photos_upload, component_id, ref, event}` with `event` either
  `{:stored, outcome}` or `{:retrying, attempt}`. A page that is gone misses it, and
  nothing else depends on it: the file is in the library either way, and the timeline
  shows it when its renditions are ready.

  A new file's date and shape are read here, from the staged copy
  (`PhoenixKit.Modules.Storage.ProcessFileJob.read_metadata/2`), so the timeline has a
  place for it straight away and draws it as being prepared until its sizes are made.
  """

  use Oban.Worker,
    queue: :photo_uploads,
    max_attempts: 8,
    unique: [
      keys: [:staged],
      period: :infinity,
      states: [:available, :scheduled, :executing, :retryable]
    ]

  require Logger

  alias PhoenixKit.Modules.Storage.ProcessFileJob
  alias PhoenixKit.PubSub.Manager
  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.Auth.SessionRef
  alias PhoenixKit.Users.Auth.User
  alias PhoenixKitPhotos.{Uploads, UploadStaging}

  @queue :photo_uploads
  @final [:not_allowed, :email_unconfirmed, :unsupported_type, :quota_exceeded, :file_missing]
  # Seconds to wait before attempt 2, 3, … 8.
  @backoff [5, 15, 30, 60, 120, 300, 600]

  @doc "The queue the job runs in."
  def queue, do: @queue

  @doc """
  Whether files may be handed to this job here: by default when Oban runs and this
  node runs the `photo_uploads` queue, so a host that has not declared it keeps inline
  storing. `config :phoenix_kit_photos, :store_in_background, true | false` decides
  instead (tests, or a host that wants inline storing).
  """
  @spec available?() :: boolean()
  def available? do
    case Application.get_env(:phoenix_kit_photos, :store_in_background, :auto) do
      setting when is_boolean(setting) -> setting
      _auto -> queue_running?()
    end
  end

  defp queue_running? do
    match?(%{}, Oban.check_queue(queue: @queue))
  rescue
    _ -> false
  catch
    :exit, _ -> false
  end

  @doc """
  The job for a staged file. `upload` holds `:name` and `:type` (what the browser
  said), `:user_uuid`, `:library_uuid`, and where to report: `:topic`, `:component`
  and `:ref`.
  """
  @spec new_store(Path.t(), map()) :: Oban.Job.changeset()
  def new_store(staged, upload) do
    new(%{
      "staged" => staged,
      "name" => upload.name,
      "type" => upload.type,
      "user_uuid" => to_string(upload.user_uuid),
      "library_uuid" => to_string(upload.library_uuid),
      "topic" => upload.topic,
      "component" => upload.component,
      "ref" => upload.ref
    })
  end

  @impl Oban.Worker
  def backoff(%Oban.Job{attempt: attempt}),
    do: Enum.at(@backoff, attempt - 1, List.last(@backoff))

  # A video to a slow bucket can take minutes; Lifeline's rescue_after must stay above this.
  @impl Oban.Worker
  def timeout(_job), do: :timer.minutes(30)

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"staged" => staged} = args} = job) do
    outcome = store(staged, args)

    if retry?(outcome) and job.attempt < job.max_attempts do
      report(args, {:retrying, job.attempt})
      {:error, outcome}
    else
      UploadStaging.discard(staged)
      report(args, {:stored, outcome})
      :ok
    end
  end

  defp store(staged, args) do
    cond do
      not UploadStaging.staged?(staged) -> {:error, :file_missing}
      not File.regular?(staged) -> {:error, :file_missing}
      true -> store_as_uploader(staged, args)
    end
  end

  defp store_as_uploader(staged, args) do
    with %User{} = user <- Auth.get_user(args["user_uuid"]),
         {:ok, scope} <- SessionRef.scope_for_user(user) do
      entry = %{client_name: args["name"], client_type: args["type"]}

      staged
      |> Uploads.store(entry, scope, args["library_uuid"])
      |> tap(&read_now(&1, staged))
    else
      refusal -> refused(refusal, args)
    end
  end

  # Why the account stores nothing, said as exactly as the page can use it, and logged:
  # the job ends "completed" either way, so the log is where a refusal can be found.
  defp refused({:error, :unconfirmed}, args) do
    Logger.info(
      "[StoreUploadJob] #{inspect(args["name"])} not stored: the email of user #{args["user_uuid"]} is not confirmed"
    )

    {:error, :email_unconfirmed}
  end

  defp refused(refusal, args) do
    Logger.info(
      "[StoreUploadJob] #{inspect(args["name"])} not stored: user #{args["user_uuid"]} was refused (#{inspect(refusal)})"
    )

    {:error, :not_allowed}
  end

  # The new file's date and shape are read from the staged copy while it is still here,
  # so the timeline gives it its place at once (a tile being prepared) instead of when
  # the processing job has fetched the file back from storage. A core without
  # `read_metadata/2` leaves it to that job, as before.
  defp read_now({:added, %{uuid: uuid, status: "processing"}}, staged) do
    if Code.ensure_loaded?(ProcessFileJob) and
         function_exported?(ProcessFileJob, :read_metadata, 2),
       do: ProcessFileJob.read_metadata(to_string(uuid), staged)
  rescue
    error ->
      Logger.warning("[StoreUploadJob] reading metadata failed: #{Exception.message(error)}")
  end

  defp read_now(_outcome, _staged), do: :ok

  defp retry?({:error, reason}), do: reason not in @final
  defp retry?(_outcome), do: false

  defp report(%{"topic" => topic, "component" => component, "ref" => ref}, event)
       when is_binary(topic) and is_binary(ref) do
    Manager.broadcast(topic, {:phoenix_kit_photos_upload, component, ref, event})
  end

  defp report(_args, _event), do: :ok
end
