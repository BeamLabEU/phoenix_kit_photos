defmodule PhoenixKitPhotos.InfoPanelTest do
  use PhoenixKitPhotos.DataCase, async: false

  alias PhoenixKitPhotos.Components.InfoPanel

  setup do
    owner = user_fixture("info-owner-#{System.unique_integer([:positive])}@example.com")
    library = library_fixture(owner)
    photo = file_fixture(owner, %{library_uuid: library.uuid})
    {:ok, socket} = InfoPanel.mount(%Phoenix.LiveView.Socket{})

    {:ok, socket} =
      InfoPanel.update(
        %{
          id: "info",
          scope: {:library, library.uuid},
          auth: scope_for(owner),
          file_uuid: photo.uuid
        },
        socket
      )

    %{socket: socket, owner: owner, photo: photo}
  end

  test "a change of reader rechecks the photo even when its id stays the same", ctx do
    assert ctx.socket.assigns.details.editor?
    stranger = user_fixture("info-stranger-#{System.unique_integer([:positive])}@example.com")

    for extra <- [%{}, %{file_uuid: ctx.photo.uuid}] do
      {:ok, socket} = InfoPanel.update(Map.put(extra, :auth, scope_for(stranger)), ctx.socket)
      assert socket.assigns.details == nil
      assert socket.assigns.editing == nil
    end
  end

  test "a late place name cannot overwrite the photo's new place", ctx do
    old_lookup = {59.437, 24.745, "en", :exact}
    new_place = %{name: "New place", lookup: nil}
    details = %{ctx.socket.assigns.details | place: new_place}
    socket = Phoenix.Component.assign(ctx.socket, :details, details)

    {:noreply, socket} =
      InfoPanel.handle_async(
        :place_name,
        {:ok, {ctx.photo.uuid, old_lookup, "Old street"}},
        socket
      )

    assert socket.assigns.details.place == new_place

    # A result for the current lookup is still applied.
    current_place = %{name: nil, lookup: old_lookup}
    details = %{socket.assigns.details | place: current_place}
    socket = Phoenix.Component.assign(socket, :details, details)

    {:noreply, socket} =
      InfoPanel.handle_async(
        :place_name,
        {:ok, {ctx.photo.uuid, old_lookup, "Old street"}},
        socket
      )

    assert socket.assigns.details.place == %{name: "Old street", lookup: nil}
  end
end
