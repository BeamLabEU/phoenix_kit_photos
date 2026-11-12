defmodule PhoenixKitPhotos.LiveUpdates do
  @moduledoc """
  Forwards storage lifecycle messages from the host LiveView to its timelines.

  Add `on_mount {PhoenixKitPhotos.LiveUpdates, "timeline-component-id"}` to
  each host LiveView, or pass a list of component IDs for multiple timelines.
  Components cannot receive PubSub messages themselves. This hook consumes
  storage lifecycle messages. Hosts with their own handlers can instead
  forward `send_update(PhotoTimeline, id: id, refresh: true, file_uuids: ids)` themselves
  (`file_uuids` is optional: with it, a timeline whose library the files are not in does nothing;
  without it, it refreshes).

  It also carries the uploader's results back to it. On a connected mount it subscribes
  the page to a topic of its own (`upload_topic/0` reads it, in the page's process) and
  relays what `PhoenixKitPhotos.StoreUploadJob` reports there to the
  `PhoenixKitPhotos.Components.PhotoUploader` it names. That is what lets the uploader
  store files in the background: without this hook on its page it stores them inline,
  while the page waits. And it tells an uploader that asked (`watch_processed/1`) which
  files finished processing, so its tiles stop saying *Making previews…* at once.

  And it relays a person's fetches from a link (`PhoenixKitPhotos.Fetches`) to the
  components that asked (`watch_fetches/3`: the library's `LinkFetcher`, the Fetches
  list), as `send_update(module, id: id, fetch_event: {:fetch, fetch} | {:removed, uuid})`.
  """

  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.PubSub.Manager
  alias PhoenixKitPhotos.Components.{PhotoTimeline, PhotoUploader}

  @upload_topic_key {__MODULE__, :upload_topic}
  @watching_key {__MODULE__, :watching_processed}
  @fetch_watchers_key {__MODULE__, :watching_fetches}
  @fetch_topics_key {__MODULE__, :fetch_topics}

  @events [
    :phoenix_kit_file_processed,
    :phoenix_kit_file_thumbnail_updated,
    :phoenix_kit_file_trashed,
    :phoenix_kit_file_restored,
    :phoenix_kit_file_deleted,
    :phoenix_kit_files_trashed,
    :phoenix_kit_files_restored,
    :phoenix_kit_files_deleted
  ]

  @doc """
  The topic the uploader on this page reports to, or nil when the page has none (not
  connected, or no `LiveUpdates` hook). Read in the page's process: a component runs
  there.
  """
  @spec upload_topic() :: String.t() | nil
  def upload_topic, do: Process.get(@upload_topic_key)

  @doc """
  Asks that the `PhotoUploader` with this id be told when files finish processing
  (`send_update(PhotoUploader, id: id, files_processed: uuids)`), which is how its tiles
  know a new photo can be shown. Called by the uploader, in the page's process; does
  nothing more on a page without this hook.
  """
  @spec watch_processed(String.t()) :: :ok
  def watch_processed(component_id) do
    Process.put(@watching_key, Enum.uniq([component_id | Process.get(@watching_key, [])]))
    :ok
  end

  @doc """
  Asks that the component `module` with this id be told about the fetches of the person
  `user_uuid`: their page subscribes (once per person) and relays each change as
  `send_update(module, id: component_id, fetch_event: event)`. Called by the component,
  in the page's process; does nothing more on a page without this hook.
  """
  @spec watch_fetches(module(), String.t(), String.t() | nil) :: :ok
  def watch_fetches(_module, _component_id, nil), do: :ok

  def watch_fetches(module, component_id, user_uuid) do
    topics = Process.get(@fetch_topics_key, MapSet.new())

    unless MapSet.member?(topics, user_uuid) do
      PhoenixKitPhotos.Fetches.subscribe(user_uuid)
      Process.put(@fetch_topics_key, MapSet.put(topics, user_uuid))
    end

    Process.put(
      @fetch_watchers_key,
      Map.put(Process.get(@fetch_watchers_key, %{}), component_id, module)
    )

    :ok
  end

  def on_mount(ids, _params, _session, socket) do
    if Phoenix.LiveView.connected?(socket) do
      Storage.subscribe_to_file_events()
      subscribe_file_changes()
      subscribe_uploads()
    end

    socket =
      Phoenix.LiveView.attach_hook(socket, __MODULE__, :handle_info, fn
        {:phoenix_kit_photos_upload, component, ref, event}, socket when is_binary(component) ->
          Phoenix.LiveView.send_update(PhotoUploader, id: component, upload_event: {ref, event})
          {:halt, socket}

        {:phoenix_kit_photos_fetch, fetch}, socket ->
          tell_fetchers({:fetch, fetch})
          {:halt, socket}

        {:phoenix_kit_photos_fetch_removed, uuid}, socket ->
          tell_fetchers({:removed, uuid})
          {:halt, socket}

        # Stacked, unstacked, dated by hand: the timeline is read again, like for an upload.
        {:phoenix_kit_files_changed, file_ids}, socket ->
          for id <- List.wrap(ids) do
            Phoenix.LiveView.send_update(PhotoTimeline,
              id: id,
              refresh: true,
              file_uuids: List.wrap(file_ids)
            )
          end

          {:halt, socket}

        {event, file_ids}, socket when event in @events ->
          for id <- List.wrap(ids) do
            Phoenix.LiveView.send_update(PhotoTimeline,
              id: id,
              refresh: true,
              file_uuids: List.wrap(file_ids)
            )
          end

          if event == :phoenix_kit_file_processed, do: tell_uploaders(List.wrap(file_ids))

          if event in [
               :phoenix_kit_file_trashed,
               :phoenix_kit_file_deleted,
               :phoenix_kit_files_trashed,
               :phoenix_kit_files_deleted
             ] &&
               socket.assigns[:viewer_file] &&
               socket.assigns.viewer_file.file_uuid in List.wrap(file_ids) do
            send(self(), :photos_viewer_closed)
          end

          {:halt, socket}

        _message, socket ->
          {:cont, socket}
      end)

    {:cont, socket}
  end

  defp tell_fetchers(event) do
    for {id, module} <- Process.get(@fetch_watchers_key, %{}) do
      Phoenix.LiveView.send_update(module, id: id, fetch_event: event)
    end

    :ok
  end

  defp tell_uploaders(file_uuids) do
    for id <- Process.get(@watching_key, []) do
      Phoenix.LiveView.send_update(PhotoUploader, id: id, files_processed: file_uuids)
    end

    :ok
  end

  # One topic per page, so a result reaches only the page whose uploader staged the file.
  # A page mounted twice in one process (a nested LiveView has its own) keeps its first.
  # Stacks and dates set by hand are announced on a topic of their own
  # (`Storage.subscribe_to_file_changes/0`).
  defp subscribe_file_changes, do: Storage.subscribe_to_file_changes()

  defp subscribe_uploads do
    if is_nil(upload_topic()) do
      topic = "phoenix_kit_photos:uploads:" <> Base.url_encode64(:crypto.strong_rand_bytes(12))
      Manager.subscribe(topic)
      Process.put(@upload_topic_key, topic)
    end

    :ok
  end
end
