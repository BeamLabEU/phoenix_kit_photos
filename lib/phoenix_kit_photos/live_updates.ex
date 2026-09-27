defmodule PhoenixKitPhotos.LiveUpdates do
  @moduledoc """
  Forwards storage lifecycle messages from the host LiveView to its timelines.

  Add `on_mount {PhoenixKitPhotos.LiveUpdates, "timeline-component-id"}` to
  each host LiveView, or pass a list of component IDs for multiple timelines.
  Components cannot receive PubSub messages themselves. This hook consumes
  storage lifecycle messages. Hosts with their own handlers can instead
  forward `send_update(PhotoTimeline, id: id, refresh: true)` themselves.
  """

  alias PhoenixKit.Modules.Storage
  alias PhoenixKitPhotos.Components.PhotoTimeline

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

  def on_mount(ids, _params, _session, socket) do
    if Phoenix.LiveView.connected?(socket), do: Storage.subscribe_to_file_events()

    socket =
      Phoenix.LiveView.attach_hook(socket, __MODULE__, :handle_info, fn
        {event, file_ids}, socket when event in @events ->
          for id <- List.wrap(ids) do
            Phoenix.LiveView.send_update(PhotoTimeline, id: id, refresh: true)
          end

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
end
